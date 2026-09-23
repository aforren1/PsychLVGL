function varargout = PsychLVGLSubjects(verb, varargin)
% PSYCHLVGLSUBJECTS  Subjects and data bindings of an XML user interface.
%   LVGL's XML format keeps shared values in subjects and binds widgets to
%   them (bind_value, bind_text, bind_checked, bind_flag_if_*, ...). LVGL
%   runs those bindings as callbacks inside the library; PsychLVGL has no
%   callbacks into MATLAB, so this helper keeps the subjects in a MATLAB
%   struct instead and moves values once per frame through the event ring.
%
%   PsychLVGLLoadXML fills the table and returns it as named.subjects. Keep
%   it and pass it back each frame:
%
%     [root, named] = PsychLVGLLoadXML('main.xml');
%     while running
%         [ui, E] = PsychLVGLFrame(ui);
%         [named.subjects, changed] = PsychLVGLSubjects('update', named.subjects, E);
%         contrast = PsychLVGLSubjects('get', named.subjects, 'contrast');
%         ...
%     end
%
%   Verbs:
%     S = PsychLVGLSubjects('create')
%         An empty table.
%     S = PsychLVGLSubjects('add', S, name, type, value [, min, max])
%         A subject. type is 'int', 'float' or 'string'. Numeric values are
%         kept between min and max.
%     S = PsychLVGLSubjects('bind', S, kind, target, subject, ...)
%         A binding of widget handle target to the subject:
%           'value',   target, subject, widget   slider, bar, arc, spinbox,
%                      roller (selected row) or dropdown (selected option);
%                      both directions
%           'checked', target, subject           LV_STATE_CHECKED; both ways
%           'text',    target, subject, fmt      label text, sprintf(fmt, v)
%                      or the plain value when fmt is ''
%           'flag',    target, subject, setter, op, ref
%                      PsychLVGL(setter, target, v op ref), with a per-flag
%                      setter such as 'ObjSetHidden'
%           'state',   target, subject, state, op, ref
%                      set the state ('LV_STATE_DISABLED') while v op ref
%                      holds. op is eq, not_eq, gt, ge, lt or le
%           'style',   target, subject, style, selector, ref
%                      add the style handle while v == ref
%           'style_prop', target, subject, setter, selector
%                      call PsychLVGL(setter, target, v, selector)
%     S = PsychLVGLSubjects('trigger', S, target, event, action, subject, ...)
%         Change a subject when the widget sends the event ('CLICKED', ...):
%           'set', value      | 'toggle'
%           'increment', step, min, max, rollover
%     S = PsychLVGLSubjects('apply', S)
%         Push every subject to its bound widgets.
%     [S, changed] = PsychLVGLSubjects('update', S, E)
%         Read the rows of E from PsychLVGL('Poll') or PsychLVGLFrame: a
%         bound widget whose value changed updates its subject, a trigger
%         fires, and every subject that changed is pushed to the widgets
%         bound to it. changed lists the names of those subjects.
%     S = PsychLVGLSubjects('set', S, name, value)
%         Set a subject from the script and push it.
%     v = PsychLVGLSubjects('get', S, name)
%
%   A binding whose widget was deleted is dropped the next time it would be
%   written. The helper keeps no state of its own; everything is in S.

    switch verb
        case 'create'
            varargout{1} = create();
        case 'add'
            varargout{1} = add(varargin{:});
        case 'bind'
            varargout{1} = bind(varargin{:});
        case 'trigger'
            varargout{1} = trigger(varargin{:});
        case 'apply'
            S = varargin{1};
            for k = 1:numel(S.names)
                S = push(S, k, 0);
            end
            varargout{1} = S;
        case 'update'
            [varargout{1}, varargout{2}] = update(varargin{:});
        case 'set'
            S = varargin{1};
            k = find_subject(S, varargin{2});
            S = assign(S, k, varargin{3});
            varargout{1} = push(S, k, 0);
        case 'get'
            S = varargin{1};
            varargout{1} = S.values{find_subject(S, varargin{2})};
        otherwise
            error('psychlvgl:Usage', 'unknown PsychLVGLSubjects verb "%s"', verb);
    end
end

function S = create()
    S = struct();
    S.names = {};
    S.types = {};
    S.values = {};
    S.min = zeros(1, 0);
    S.max = zeros(1, 0);
    S.binds = struct('kind', {}, 'target', {}, 'subject', {}, 'args', {});
    S.bindTarget = zeros(1, 0);
    S.bindSubject = zeros(1, 0);
    S.trigs = struct('target', {}, 'code', {}, 'action', {}, 'subject', {}, 'args', {});
    S.trigTarget = zeros(1, 0);
    S.trigCode = zeros(1, 0);
    S.codeValueChanged = PsychLVGL('Enum', 'LV_EVENT_VALUE_CHANGED');
end

function S = add(S, name, type, value, lo, hi)
    if nargin < 5; lo = -Inf; end
    if nargin < 6; hi = Inf; end
    if ~ischar(name) || isempty(name)
        error('psychlvgl:Usage', 'a subject name must be a non-empty char row vector');
    end
    if any(strcmp(S.names, name))
        error('psychlvgl:Usage', 'subject "%s" exists already', name);
    end
    if ~any(strcmp(type, {'int', 'float', 'string'}))
        error('psychlvgl:Usage', 'subject type must be int, float or string, not "%s"', type);
    end
    S.names{end+1} = name;
    S.types{end+1} = type;
    S.min(end+1) = lo;
    S.max(end+1) = hi;
    S.values{end+1} = [];
    S = assign(S, numel(S.names), value);
end

function k = find_subject(S, name)
    k = find(strcmp(S.names, name), 1);
    if isempty(k)
        error('psychlvgl:Usage', 'unknown subject "%s"', name);
    end
end

function S = assign(S, k, v)
    switch S.types{k}
        case 'string'
            if isnumeric(v)
                v = num2str(v);
            end
        case 'int'
            v = min(max(round(double(v)), S.min(k)), S.max(k));
        otherwise
            v = min(max(double(v), S.min(k)), S.max(k));
    end
    S.values{k} = v;
end

function S = bind(S, kind, target, subject, varargin)
    k = find_subject(S, subject);
    switch kind
        case {'value', 'checked'}
            % VALUE_CHANGED is in the default event mask; asking again costs
            % nothing and keeps the binding working if a script removed it.
            PsychLVGL('AddEvent', target, 'VALUE_CHANGED');
        case {'text', 'flag', 'state', 'style', 'style_prop'}
        otherwise
            error('psychlvgl:Usage', 'unknown binding kind "%s"', kind);
    end
    S.binds(end+1) = struct('kind', kind, 'target', target, 'subject', k, 'args', {varargin});
    S.bindTarget(end+1) = target;
    S.bindSubject(end+1) = k;
end

function S = trigger(S, target, event, action, subject, varargin)
    k = find_subject(S, subject);
    if ~any(strcmp(action, {'set', 'toggle', 'increment'}))
        error('psychlvgl:Usage', 'unknown trigger action "%s"', action);
    end
    if ischar(event)
        code = PsychLVGL('Enum', ['LV_EVENT_' upper(event)]);
    else
        code = event;
    end
    PsychLVGL('AddEvent', target, code);
    S.trigs(end+1) = struct('target', target, 'code', code, 'action', action, ...
                            'subject', k, 'args', {varargin});
    S.trigTarget(end+1) = target;
    S.trigCode(end+1) = code;
end

function [S, changedNames] = update(S, E)
    changedNames = {};
    if isempty(E) || (isempty(S.bindTarget) && isempty(S.trigTarget))
        return;
    end
    changed = false(1, numel(S.names));
    source = zeros(1, numel(S.names));
    rows = find(ismember(E(:, 1), [S.bindTarget S.trigTarget]))';
    for r = rows
        tgt = E(r, 1);
        code = E(r, 2);
        if code == S.codeValueChanged
            for b = find(S.bindTarget == tgt)
                B = S.binds(b);
                switch B.kind
                    case 'value'
                        v = E(r, 4);
                    case 'checked'
                        v = double(PsychLVGL('ObjHasState', tgt, 'LV_STATE_CHECKED'));
                    otherwise
                        continue;
                end
                k = B.subject;
                if ~isequal(S.values{k}, v)
                    S = assign(S, k, v);
                    changed(k) = true;
                    source(k) = b;
                end
            end
        end
        for t = find(S.trigTarget == tgt & S.trigCode == code)
            T = S.trigs(t);
            k = T.subject;
            old = S.values{k};
            switch T.action
                case 'set'
                    S = assign(S, k, T.args{1});
                case 'toggle'
                    S = assign(S, k, double(~(old ~= 0)));
                case 'increment'
                    step = T.args{1};
                    lo = max(T.args{2}, S.min(k));
                    hi = min(T.args{3}, S.max(k));
                    v = old + step;
                    if v > hi
                        if T.args{4}; v = lo; else; v = hi; end
                    elseif v < lo
                        if T.args{4}; v = hi; else; v = lo; end
                    end
                    S = assign(S, k, v);
            end
            if ~isequal(old, S.values{k})
                changed(k) = true;
                source(k) = 0;
            end
        end
    end
    for k = find(changed)
        S = push(S, k, source(k));
    end
    changedNames = S.names(changed);
end

function S = push(S, k, skip)
% Writes subject k to every widget bound to it, except binding skip, the
% widget the value came from. A binding whose widget is gone is dropped.
    v = S.values{k};
    dead = false(1, numel(S.binds));
    for b = find(S.bindSubject == k)
        if b == skip
            continue;
        end
        B = S.binds(b);
        try
            write_binding(B, v);
        catch err
            if ~PsychLVGL('IsValid', B.target)
                dead(b) = true;
            else
                rethrow(err);
            end
        end
    end
    if any(dead)
        S.binds(dead) = [];
        S.bindTarget(dead) = [];
        S.bindSubject(dead) = [];
    end
end

function write_binding(B, v)
    t = B.target;
    a = B.args;
    switch B.kind
        case 'value'
            switch a{1}
                case 'slider'
                    PsychLVGL('SliderSetValue', t, v, false);
                case 'bar'
                    PsychLVGL('BarSetValue', t, v, false);
                case 'arc'
                    PsychLVGL('ArcSetValue', t, v);
                case 'spinbox'
                    PsychLVGL('SpinboxSetValue', t, v);
                case 'roller'
                    PsychLVGL('RollerSetSelected', t, v, false);
                case 'dropdown'
                    PsychLVGL('DropdownSetSelected', t, v);
                otherwise
                    error('psychlvgl:Usage', 'bind_value is not supported on a %s', a{1});
            end
        case 'checked'
            if v ~= 0
                PsychLVGL('ObjAddState', t, 'LV_STATE_CHECKED');
            else
                PsychLVGL('ObjRemoveState', t, 'LV_STATE_CHECKED');
            end
        case 'text'
            if ~isempty(a) && ~isempty(a{1})
                s = sprintf(a{1}, v);
            elseif ischar(v)
                s = v;
            else
                s = num2str(v);
            end
            PsychLVGL('LabelSetText', t, s);
        case {'flag', 'state'}
            on = compare(v, a{2}, a{3});
            if strcmp(B.kind, 'flag')
                PsychLVGL(a{1}, t, on);
            elseif on
                PsychLVGL('ObjAddState', t, a{1});
            else
                PsychLVGL('ObjRemoveState', t, a{1});
            end
        case 'style'
            if isequal(v, a{3})
                PsychLVGL('ObjAddStyle', t, a{1}, a{2});
            else
                PsychLVGL('ObjRemoveStyle', t, a{1}, a{2});
            end
        case 'style_prop'
            PsychLVGL(a{1}, t, v, a{2});
    end
end

function tf = compare(v, op, ref)
    switch op
        case 'eq'
            tf = v == ref;
        case 'not_eq'
            tf = v ~= ref;
        case 'gt'
            tf = v > ref;
        case 'ge'
            tf = v >= ref;
        case 'lt'
            tf = v < ref;
        case 'le'
            tf = v <= ref;
        otherwise
            error('psychlvgl:Usage', 'unknown comparison "%s"', op);
    end
end
