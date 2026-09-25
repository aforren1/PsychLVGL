function ev = plv_raw_events(rows)
% PLV_RAW_EVENTS  Builds the raw device log from an Nx6 row matrix.
%
%   ev = plv_raw_events(rows)   rows are [time device kind code pressed cooked]
%   with kind 1 key, 2 button, 3 wheel. ev is an Nx1 struct array with the
%   fields time, device, kind, code, name, pressed, cooked; 0x1 when rows is
%   empty, so [ev.time] and numel(ev) always work.
%
%   Poll runs every frame, so the struct array is made by one struct() call
%   from cell columns rather than grown one element at a time.

    if nargin < 1 || isempty(rows)
        rows = zeros(0, 6);
    end
    n = size(rows, 1);
    kinds = {'key', 'button', 'wheel'};
    kind = cell(n, 1);
    name = repmat({''}, n, 1);
    haveKbName = n > 0 && any(rows(:, 3) == 1) && exist('KbName', 'file') ~= 0;
    buttons = {'left', 'middle', 'right'};
    axes = {'vertical', 'horizontal'};
    for k = 1:n
        kind{k} = kinds{rows(k, 3)};
        code = rows(k, 4);
        switch rows(k, 3)
            case 1
                if haveKbName && code >= 1
                    name{k} = plv_kbname(code);
                end
            case 2
                if any(code == 1:3); name{k} = buttons{code}; end
            case 3
                if any(code == 1:2); name{k} = axes{code}; end
        end
    end
    ev = struct('time', num2cell(rows(:, 1)), 'device', num2cell(rows(:, 2)), ...
                'kind', kind, 'code', num2cell(rows(:, 4)), 'name', name, ...
                'pressed', num2cell(rows(:, 5)), 'cooked', num2cell(rows(:, 6)));
    ev = reshape(ev, n, 1);
end

function s = plv_kbname(code)
    try
        s = KbName(code);
        if iscell(s); s = s{1}; end
        if ~ischar(s); s = ''; end
    catch
        s = '';
    end
end
