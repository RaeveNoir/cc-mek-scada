--
-- Message Queue
--

TYPE = {
    COMMAND = 0,
    PACKET = 1
}

function new()
    local queue = {}

    local length = function ()
        return #queue
    end

    local empty = function ()
        return #queue == 0
    end
    
    local _push = function (qtype, message)
        table.insert(queue, { qtype = qtype, message = message })
    end
    
    local push_packet = function (message)
        push(TYPE.PACKET, message)
    end
    
    local push_command = function (message)
        push(TYPE.COMMAND, message)
    end
    
    local pop = function ()
        if #queue > 0 then
            return table.remove(queue)
        else 
            return nil
        end
    end

    return {
        length = length,
        empty = empty,
        push_packet = push_packet,
        push_command = push_command,
        pop = pop
    }
end
