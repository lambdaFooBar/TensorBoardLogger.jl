export summary_iterator

"""
    is_valid_event(f::IOStream) => Bool

Returns true if the stream points to a valid TensorBoard event, false overwise.
This is accomplished by checeking the crc checksum on the header (first 8
bytes) of the event.
"""
function is_valid_event(f::IOStream)
    eof(f) && return false

    header = read(f, 8)
    length(header) != 8 && return false

    crc_header = read(f, 4)
    length(crc_header) != 4 && return false

    # check
    crc_header_ck = reinterpret(UInt8, UInt32[masked_crc32c(header)])
    return crc_header == crc_header_ck
end


"""
    read_event(f::IOStream) => Event

Reads the stream `f`, assuming it's encoded according to TensorBoard format,
and decodes a single event.
This function assumes that `eof(f) == false`.
"""
function read_event(f::IOStream)
    header = read(f, 8)
    crc_header = read(f, 4)

    # check
    crc_header_ck = reinterpret(UInt8, UInt32[masked_crc32c(header)])
    if crc_header != crc_header_ck
        error("Invalid event checksum for stream", f)
    end

    # read data
    data_len = first(reinterpret(Int64, header))
    data = read(f, data_len)
    crc_data = read(f, 4)

    # check
    crc_data_ck = reinterpret(UInt8, UInt32[masked_crc32c(data)])
    @assert crc_data == crc_data_ck

    pb = PipeBuffer(data)
    ev = readproto(pb, Event())
    return ev
end

"""
    TBEventFileCollectionIterator(path; purge=true)

Iterate along all event-files in the folder `path`.
When the keyword argument `purge==true`, if the i+1-th file begins with a purge
at step `s`, the i-th file is read only up to step `s`.
"""
struct TBEventFileCollectionIterator
    dir::String
    files::Vector{String}

    purge::Bool
end

TBEventFileCollectionIterator(logger::TBReadable; purge=true) =
    TBEventFileCollectionIterator(logdir(logger), purge=true)

function TBEventFileCollectionIterator(path; purge=true)
    fnames = sort(readdir(path))
    good_fnames = typeof(fnames)()

    # Only consider files whose first event file would be valid.
    # So if there are other files in this folder, we ignore them.
    for fname in fnames
        open(joinpath(path,fname), "r") do f
            is_valid_event(f) && push!(good_fnames, fname)
        end
    end

    @debug "Valid TensorBoard event files" good_fnames

    TBEventFileCollectionIterator(path, good_fnames, purge)
end

function Base.iterate(it::TBEventFileCollectionIterator, state=1)
    state > length(it.files) && return nothing
    fstream = open(joinpath(it.dir, it.files[state]))

    purge_step = typemax(Int) # default value (no purging)
    # If there is a logfile after this one, read the first event and check
    # if we should purge some steps.
    if state+1 <= length(it.files)
        for ev=TBEventFileIterator(open(joinpath(it.dir,it.files[state+1])))
            if ev.step != 0
                purge_step = ev.step
            end
            break
        end
    end

    return TBEventFileIterator(fstream, purge_step), state+1
end

"""
    TBEventFileIterator(fstream, stop_at_step=∞)

Iterator for iterating along a fstream.
The optional argument `stop_at_step` tells at what step the iterator should stop.
"""
struct TBEventFileIterator
    fstream::IOStream
    stop_at_step::Int
end
TBEventFileIterator(fstream) = TBEventFileIterator(fstream, typemax(Int))

function Base.iterate(it::TBEventFileIterator, state=0)
    if eof(it.fstream) 
        close(it.fstream)
        return nothing
    end
    ev=read_event(it.fstream)
    if ev.step >= it.stop_at_step
        @info "stopping!!!!!"
        close(it.fstream)
        return nothing
    end
    return ev, state+1
end

"""
    summary_type(summary)

Returns the type of a summary
"""
function summary_type(summary)
    if hasproperty(summary, :histo)
        return :histo
    elseif hasproperty(summary, :image)
        return :image
    elseif hasproperty(summary, :audio)
        return :audio
    elseif hasproperty(summary, :tensor)
        return :tensor
    #elseif hasproperty(summary, :simple_value)
    end
    # always defined
    return :simple_value
end

"""
    iterate(evs::Summary, state=1)

Iterate along all summaries stored inside an event, automatically returning the
correct value (histogram, audio, image or scalar).
"""
function Base.iterate(evs::Summary, state=1)
    summaries = evs.value

    state > length(summaries) && return nothing
    summary = summaries[state]

    tag = summary.tag
    Δ_state = 0

    return (tag, summary), state + 1
end

struct SummaryDeserializingIterator
    summary::Summary
    smart::Bool
end

"""
    SummaryDeserializingIterator(summary; smart=true)

Creates an iterator that deserializes all entries in a (proto)summary collection.
If `smart == true` then attempts to recombine some types that are decomposed
upon serialization to tensorboard (such as real/imaginary parts, 3D images, etc...)

!!! Warn
    `smart = true` has not been tested with files generated by TensorFlow. It
    should work, but it might give silent errors.
"""
SummaryDeserializingIterator(summ; smart=true) =
    SummaryDeserializingIterator(summ, smart)


function Base.iterate(iter::SummaryDeserializingIterator, state=1)
    evs = iter.summary
    res = iterate(evs, state)
    res == nothing && return nothing

    (tag, summary), i_state = res

    typ = summary_type(summary)

    if typ === :histo
        val = deserialize_histogram_summary(summary)
        tag, val, state = lookahead_deserialize(tag, val, evs, state, :histo)
    elseif typ === :image
        val = deserialize_image_summary(summary)
        tag, val, state = lookahead_deserialize(tag, val, evs, state, :image)
    elseif typ === :audio
        val = deserialize_audio_summary(summary)
    elseif typ === :tensor
        val = deserialize_tensor_summary(summary)
    elseif typ === :simple_value
        val = summary.simple_value
        tag, val, state = lookahead_deserialize(tag, val, evs, state, :simple_value)
    else
        @error "Event with unknown field" summary=summary
    end

    return (tag, val), state + 1
end

"""
    map_summaries(fun, path; purge=true, tags=all, steps=all, smart=true)

Maps the function `fun(name, value)` on all the values logged to the folder
at `path`. The function is called sequentially, starting from the first
event till the last.

When the keyword argument `purge==true`, if the i+1-th file begins with a purge
at step `s`, the i-th file is read only up to step `s`.

`fun` should take 3 arguments:
    (1) a String representing the name/tag of the logged value
    (2) an Integer, representing the step number
    (3) a value, which can be of the following types:

Optional kwargs `tags` takes as input a collection of Strings, and will only
iterate across tags summaries with a tag in that collection.

Optional kwargs `steps` takes as input a collection of integers, and will
only iterate across events with step within that collection.

Optional kwarg `smart=[true]` attempts to reconstruct N-dimensional arrays, complex
values and 3-dim images, that are decomposed when serialzied to tensorboard. This
feature works with .proto files generated by TensorBoardLogger itself, but it is
untested with files generated by TensorFlow.
"""
function map_summaries(fun::Function, logdir; purge=true, tags=nothing, steps=nothing, smart=true)
    if tags isa AbstractString
        s = Set{typeof(tags)}()
        push!(s, tags)
        tags = s
    end

    for event_file in TBEventFileCollectionIterator(logdir, purge=purge)
        for event in event_file
            # if event.summary is not defined, don't bother processing this event,
            # as it's probably a "start file" event or a graph event.
            !hasproperty(event, :summary) && continue

            step = event.step
            steps !== nothing && step ∉ steps && continue

            iter = SummaryDeserializingIterator(event.summary, smart)
            for (name, val) in iter
                tags !== nothing && name ∉ tags && continue

                fun(name, step, val)
            end
        end
    end
end


"""
    map_summaries(fun, path; purge=true, steps=all)

Maps the function `fun(event)` on all the event logged to the folder
at `path`. The function is called sequentially, starting from the first
event till the last.

When the keyword argument `purge==true`, if the i+1-th file begins with a purge
at step `s`, the i-th file is read only up to step `s`.

Also metadata events, without any real data attached are mapped.
You can detect those by `hasproperty(event, :summary) == false`

Optional kwargs `steps` takes as input a collection of integers, and will
only iterate across events with step within that collection.
"""
function map_events(fun::Function, logdir; purge=true, steps=nothing)
    for event_file in TBEventFileCollectionIterator(logdir, purge=purge)
        for event in event_file
            step = event.step
            steps !== nothing && step ∈ steps

            fun(event)
        end
    end
end
