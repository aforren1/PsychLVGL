function [kbd, mouse] = plv_input_indices(opts)
% PLV_INPUT_INDICES  Checks opts.KeyboardIndex and opts.MouseIndex.
%
%   [kbd, mouse] = plv_input_indices(opts) returns both as double row
%   vectors, empty for the Psychtoolbox default. PsychLVGLOpen calls it
%   before Init and PsychLVGLInput('Start') calls it again, so a usage error
%   never leaves a half open panel.

    if ~isstruct(opts)
        error('psychlvgl:Usage', 'opts must be a struct');
    end
    kbd = plv_one(opts, 'KeyboardIndex');
    mouse = plv_one(opts, 'MouseIndex');
    both = intersect(kbd, mouse);
    if ~isempty(both)
        % One device cannot carry two queues, and mouse buttons must never
        % reach the keypad indev as keys.
        error('psychlvgl:Usage', ...
              'device %d is in both KeyboardIndex and MouseIndex', both(1));
    end
end

function v = plv_one(opts, name)
    v = [];
    if ~isfield(opts, name) || isempty(opts.(name))
        return;
    end
    v = opts.(name);
    if ~isnumeric(v) || ~isvector(v) || any(~isfinite(v)) || any(v < 0) || any(v ~= round(v))
        error('psychlvgl:Usage', '%s must be [] or a vector of device indices', name);
    end
    v = double(v(:)');
    if numel(unique(v)) ~= numel(v)
        % A second KbQueueCreate on the same device replaces the first queue.
        error('psychlvgl:Usage', '%s lists a device twice', name);
    end
end
