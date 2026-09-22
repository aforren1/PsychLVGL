function rows = PsychLVGLKeyMap(evt, shiftDown)
% PSYCHLVGLKEYMAP  Converts one KbEventGet event to LVGL key rows.
%
%   rows = PsychLVGLKeyMap(evt)             evt from KbEventGet
%   rows = PsychLVGLKeyMap(evt, shiftDown)  shiftDown changes tab to LV_KEY_PREV
%
%   rows is 0x2 or 1x2, [lvKey pressed]. An unmapped key gives 0x2.
%
%   CookedKey wins when it is set, because LVGL treats a printable code point
%   as text for text areas. Only the keys that carry no code point go through
%   the table.
%
%   The table is used when Psychtoolbox is absent, which is also what the
%   no-GL tests rely on.

    if nargin < 2; shiftDown = false; end

    rows = zeros(0, 2);
    if ~isstruct(evt); return; end

    pressed = 0;
    if isfield(evt, 'Pressed'); pressed = double(evt.Pressed ~= 0); end

    if isfield(evt, 'CookedKey') && evt.CookedKey > 0
        rows = [double(evt.CookedKey), pressed];
        return;
    end

    name = '';
    if isfield(evt, 'Keycode') && ~isempty(evt.Keycode) && exist('KbName', 'file')
        try
            name = KbName(evt.Keycode);
        catch
            name = '';
        end
    end
    if isempty(name) && isfield(evt, 'KeyName')
        name = evt.KeyName;
    end
    if iscell(name); name = name{1}; end
    if ~ischar(name) || isempty(name); return; end

    key = PsychLVGLKeyMapName(name, shiftDown);
    if key > 0
        rows = [key, pressed];
    end
end

function key = PsychLVGLKeyMapName(name, shiftDown)
% The numbers are the LV_KEY_* code points, SPEC section 6.3.
    key = 0;
    switch lower(name)
        case {'uparrow', 'up'};        key = 17;
        case {'downarrow', 'down'};    key = 18;
        case {'rightarrow', 'right'};  key = 19;
        case {'leftarrow', 'left'};    key = 20;
        case {'escape', 'esc'};        key = 27;
        case {'delete'};               key = 127;
        case {'backspace'};            key = 8;
        case {'return', 'enter'};      key = 10;
        case {'tab'}
            if shiftDown
                key = 11;   % LV_KEY_PREV
            else
                key = 9;    % LV_KEY_NEXT
            end
        case {'home'};                 key = 2;
        case {'end'};                  key = 3;
        otherwise;                     key = 0;
    end
end
