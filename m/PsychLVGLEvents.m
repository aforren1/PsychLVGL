function out = PsychLVGLEvents(cmd, E, varargin)
% PSYCHLVGLEVENTS  Reads the widget event matrix and the raw device log.
%
%   S = PsychLVGLEvents('decode', E)
%       Struct array with target, name, code, currentTarget, param, time.
%
%   R = PsychLVGLEvents('filter', E, h, 'CLICKED')
%       The rows of E whose target is h and whose code is that event. Pass []
%       for either to leave it unconstrained.
%
%   R = PsychLVGLEvents('filterRaw', events, kind, code)
%       The elements of the raw device log (PsychLVGLFrame, third output)
%       with that kind ('key', 'button' or 'wheel') and code. code is a
%       number, a vector, a KbName for keys, 'left', 'middle' or 'right' for
%       buttons, or 'vertical' or 'horizontal' for the wheel. Pass [] for
%       either to leave it unconstrained. R is Mx1, 0x1 when nothing matches.
%
%   The two logs differ in form and in time. The widget event matrix is
%   filled by the MEX into one block of doubles, one row per event, and its
%   time is the time of the Update that produced the event, the same for
%   every event of a frame. The raw device log is built in MATLAB from the
%   Psychtoolbox queues, so it is a struct array with named fields, and its
%   time is when the device reported the event. Use the raw log for
%   reaction times.
%
%   The widget event matrix is the primary form because one
%   mxCreateDoubleMatrix is far cheaper per frame than a struct array.
%   Decode when readability matters.

    switch lower(cmd)
        case 'decode'
            out = do_decode(E);
        case 'filter'
            out = do_filter(E, varargin{:});
        case 'filterraw'
            out = do_filter_raw(E, varargin{:});
        otherwise
            error('psychlvgl:Usage', 'unknown PsychLVGLEvents command "%s"', cmd);
    end
end

function S = do_decode(E)
    n = size(E, 1);
    S = repmat(struct('target', 0, 'name', '', 'code', 0, ...
                      'currentTarget', 0, 'param', 0, 'time', 0), n, 1);
    for k = 1:n
        S(k).target = E(k, 1);
        S(k).code = E(k, 2);
        try
            S(k).name = PsychLVGL('EventName', E(k, 2));
        catch
            S(k).name = sprintf('CODE_%d', E(k, 2));
        end
        S(k).currentTarget = E(k, 3);
        S(k).param = E(k, 4);
        S(k).time = E(k, 5);
    end
    if n == 0
        S = S([]);
    end
end

function R = do_filter(E, h, name)
    if nargin < 2; h = []; end
    if nargin < 3; name = []; end
    keep = true(size(E, 1), 1);
    if ~isempty(h)
        keep = keep & (E(:, 1) == h);
    end
    if ~isempty(name)
        if ischar(name)
            code = PsychLVGL('Enum', ['LV_EVENT_' strrep(upper(name), 'LV_EVENT_', '')]);
        else
            code = name;
        end
        keep = keep & (E(:, 2) == code);
    end
    R = E(keep, :);
end

function R = do_filter_raw(ev, kind, code)
    if nargin < 2; kind = []; end
    if nargin < 3; code = []; end
    if isempty(ev)
        R = plv_raw_events([]);
        return;
    end
    if ~isstruct(ev) || ~isfield(ev, 'kind') || ~isfield(ev, 'code')
        error('psychlvgl:Usage', 'filterRaw wants the raw event struct array');
    end
    ev = ev(:);
    keep = true(numel(ev), 1);
    if ~isempty(kind)
        if ~ischar(kind) || ~any(strcmp(kind, {'key', 'button', 'wheel'}))
            error('psychlvgl:Usage', 'kind must be ''key'', ''button'' or ''wheel''');
        end
        keep = keep & strcmp({ev.kind}', kind);
    end
    if ~isempty(code)
        if ischar(code)
            code = plv_raw_code(kind, code);
        end
        keep = keep & ismember([ev.code]', code(:));
    end
    R = ev(keep);
end

function code = plv_raw_code(kind, name)
    switch kind
        case 'button'
            code = find(strcmpi(name, {'left', 'middle', 'right'}));
        case 'wheel'
            code = find(strcmpi(name, {'vertical', 'horizontal'}));
        case 'key'
            % KbName maps names the way the keyboard queue reports them on
            % this platform.
            if ~exist('KbName', 'file')
                error('psychlvgl:Usage', 'a key name needs KbName on the path');
            end
            code = KbName(name);
        otherwise
            error('psychlvgl:Usage', 'a code name needs a kind');
    end
    if isempty(code)
        error('psychlvgl:Usage', 'unknown code name "%s"', name);
    end
end
