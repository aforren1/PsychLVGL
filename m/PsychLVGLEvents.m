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
%   S = PsychLVGLEvents('decodeRaw', events)
%       Struct array with time, device, kind, kindName, code, name, pressed,
%       cooked, from the raw device log of PsychLVGLFrame or
%       PsychLVGLInput('Poll'). kindName is 'key', 'button' or 'wheel'.
%       name is the KbName of a key (when KbName is on the path), 'left',
%       'middle' or 'right' for a button, and 'vertical' or 'horizontal' for
%       the wheel.
%
%   R = PsychLVGLEvents('filterRaw', events, kind, code)
%       The rows of the raw log with that kind (1, 2, 3 or 'key', 'button',
%       'wheel') and code. Pass [] for either to leave it unconstrained. A
%       char code is a KbName for keys, 'left', 'middle' or 'right' for
%       buttons, and 'vertical' or 'horizontal' for the wheel.
%
%   The two logs differ in time: the time of a widget event is the time of
%   the Update that produced it, the same for every event of a frame; the
%   time of a raw row is when the device reported it. Use the raw log for
%   reaction times.
%
%   The matrix is the primary form because one mxCreateDoubleMatrix is far
%   cheaper per frame than a struct array. Decode when readability matters.

    switch lower(cmd)
        case 'decode'
            out = do_decode(E);
        case 'filter'
            out = do_filter(E, varargin{:});
        case 'decoderaw'
            out = do_decode_raw(E);
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

function S = do_decode_raw(ev)
    if isempty(ev); ev = zeros(0, 6); end
    if size(ev, 2) ~= 6
        error('psychlvgl:Usage', 'the raw event log must have 6 columns');
    end
    n = size(ev, 1);
    S = repmat(struct('time', 0, 'device', 0, 'kind', 0, 'kindName', '', ...
                      'code', 0, 'name', '', 'pressed', 0, 'cooked', 0), n, 1);
    kinds = {'key', 'button', 'wheel'};
    for k = 1:n
        S(k).time = ev(k, 1);
        S(k).device = ev(k, 2);
        S(k).kind = ev(k, 3);
        if any(ev(k, 3) == 1:3); S(k).kindName = kinds{ev(k, 3)}; end
        S(k).code = ev(k, 4);
        S(k).name = plv_raw_name(ev(k, 3), ev(k, 4));
        S(k).pressed = ev(k, 5);
        S(k).cooked = ev(k, 6);
    end
    if n == 0
        S = S([]);
    end
end

function R = do_filter_raw(ev, kind, code)
    if nargin < 2; kind = []; end
    if nargin < 3; code = []; end
    if isempty(ev); ev = zeros(0, 6); end
    keep = true(size(ev, 1), 1);
    if ischar(kind)
        kind = find(strcmpi(kind, {'key', 'button', 'wheel'}));
        if isempty(kind)
            error('psychlvgl:Usage', 'kind must be 1, 2, 3, ''key'', ''button'' or ''wheel''');
        end
    end
    if ~isempty(kind)
        keep = keep & (ev(:, 3) == kind);
    end
    if ~isempty(code)
        if ischar(code)
            code = plv_raw_code(kind, code);
        end
        keep = keep & ismember(ev(:, 4), code);
    end
    R = ev(keep, :);
end

function name = plv_raw_name(kind, code)
    name = '';
    switch kind
        case 1
            if exist('KbName', 'file')
                try
                    name = KbName(code);
                    if iscell(name); name = name{1}; end
                    if ~ischar(name); name = ''; end
                catch
                    name = '';
                end
            end
        case 2
            names = {'left', 'middle', 'right'};
            if any(code == 1:3); name = names{code}; end
        case 3
            names = {'vertical', 'horizontal'};
            if any(code == 1:2); name = names{code}; end
    end
end

function code = plv_raw_code(kind, name)
    switch kind
        case 2
            code = find(strcmpi(name, {'left', 'middle', 'right'}));
        case 3
            code = find(strcmpi(name, {'vertical', 'horizontal'}));
        otherwise
            % A key name needs KbName, which maps names the way the
            % keyboard queue reports them on this platform.
            if isempty(kind) || kind ~= 1 || ~exist('KbName', 'file')
                error('psychlvgl:Usage', 'a key name needs kind 1 and KbName on the path');
            end
            code = KbName(name);
    end
    if isempty(code)
        error('psychlvgl:Usage', 'unknown code name "%s"', name);
    end
end
