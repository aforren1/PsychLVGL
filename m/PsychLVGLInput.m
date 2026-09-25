function varargout = PsychLVGLInput(cmd, varargin)
% PSYCHLVGLINPUT  Gathers mouse, wheel and keyboard input for PsychLVGL.
%
%   kq = PsychLVGLInput('Start', win)
%   kq = PsychLVGLInput('Start', win, opts)
%   [mouse, wheel, keys, kq, events] = PsychLVGLInput('Poll', kq, win, dst, panelW, panelH)
%   PsychLVGLInput('Stop', kq)
%   d = PsychLVGLInput('Devices')
%
%   'Start' creates and starts a keyboard queue for each keyboard and, where
%   the platform supports it, a queue on each mouse that reads the wheel. kq
%   is a struct the caller keeps. opts can hold two fields:
%
%     KeyboardIndex  The keyboards to read, a vector of Psychtoolbox device
%                    indices as GetKeyboardIndices returns them. [] (default)
%                    keeps the Psychtoolbox default keyboard.
%     MouseIndex     The mice to read, a vector of device indices as
%                    GetMouseIndices returns them. [] (default) keeps the
%                    Psychtoolbox default.
%
%   On a computer with more than one keyboard or mouse, set both. The default
%   device is not always the one the participant uses. A device can appear
%   only once in the two lists together.
%
%   'Poll' returns the three arguments PsychLVGL('Update') expects. Key
%   events from all keyboards are merged in time order. The wheel clicks of
%   all mice are added. The pointer position and button 1 come from the first
%   entry of MouseIndex only; on Linux the position is read from the master
%   pointer that mouse moves, because a slave pointer reports raw device axes.
%   Mouse coordinates are panel pixels: the destination rectangle origin is
%   subtracted and the point is scaled when the destination differs in size
%   from the panel, so the script is free to draw the panel at any scale.
%   wheel is in clicks, positive for a turn away from the user. Keep the
%   fourth output: it carries the part of a wheel click that is not complete.
%
%   The wheel source depends on the platform, SPEC section 6.2:
%     Linux    With MouseIndex, a queue on each mouse; X11 reports each wheel
%              click as a press of button 4 (up) or 5 (down). Without it,
%              GetMouseWheel, which reads the first wheel mouse it finds.
%     Windows  A queue on each mouse (MouseIndex, or the first mouse, because
%              Windows combines all mice into one); DirectInput reports the
%              wheel as the third axis, 120 units for each click.
%     macOS    GetMouseWheel on each mouse. A macOS queue has no wheel.
%   When no source works, 'Poll' returns a wheel of zero and warns once.
%   Horizontal wheel clicks (buttons 6 and 7) are ignored, because the LVGL
%   encoder has one axis.
%
%   events is the raw device log of this poll, for reaction times. It is an
%   Nx1 struct array, one element per device event in time order, 0x1 when
%   there is none, with these fields:
%
%     time     GetSecs time. For an event from a queue this is the time
%              PsychHID recorded; for a polled button it is the poll time.
%     device   Psychtoolbox device index; NaN for the default keyboard queue
%              and for the default mouse.
%     kind     'key', 'button' or 'wheel'.
%     code     Key: the Psychtoolbox keycode (KbName), before the LVGL
%              mapping. Button: 1 left, 2 middle, 3 right. Wheel: 1 vertical,
%              2 horizontal.
%     name     KbName of the key when KbName is on the path; 'left',
%              'middle' or 'right'; 'vertical' or 'horizontal'; else ''.
%     pressed  1 press, 0 release. Wheel events hold the signed clicks
%              instead: vertical positive away from the user, horizontal
%              positive to the right. The vertical ones add up to wheel.
%     cooked   CookedKey of a key event, 0 for the other kinds.
%
%   Button rows carry the device time only for mice in MouseIndex that have
%   a queue (Linux and Windows). With MouseIndex empty, on macOS, or when a
%   queue fails, the rows come from changes of the GetMouse state of the
%   pointer mouse and carry the poll time, which is up to one frame late.
%   The pointer indev always uses the GetMouse state, and button events
%   never reach the keys or the wheel. PsychLVGLEvents('filterRaw', events,
%   kind, code) picks events by kind and code.
%
%   'Devices' prints the keyboards and mice and returns d.keyboards and
%   d.mice, struct arrays with the fields index, product, usageName,
%   xinputName and xinputId. On Linux, xinputName is the name that
%   `xinput list` shows and xinputId is its id; use a "slave pointer" as
%   MouseIndex. On other platforms xinputName is '' and xinputId is NaN.
%
%   Psychtoolbox is required. Without it every call returns neutral values,
%   which is what lets the no-GL tests run.
%
%   See also PSYCHLVGLOPEN, PSYCHLVGLFRAME, GETKEYBOARDINDICES, GETMOUSEINDICES.

    switch lower(cmd)
        case 'start'
            varargout{1} = do_start(varargin{:});
        case 'poll'
            [m, w, k, kq, ev] = do_poll(varargin{:});
            varargout{1} = m;
            if nargout > 1; varargout{2} = w; end
            if nargout > 2; varargout{3} = k; end
            if nargout > 3; varargout{4} = kq; end
            if nargout > 4; varargout{5} = ev; end
        case 'stop'
            do_stop(varargin{:});
        case 'devices'
            d = do_devices();
            if nargout > 0; varargout{1} = d; end
        otherwise
            error('psychlvgl:Usage', 'unknown PsychLVGLInput command "%s"', cmd);
    end
end

% --- Start ------------------------------------------------------------------

function kq = do_start(win, opts)
    if nargin < 1; win = []; end
    if nargin < 2 || isempty(opts); opts = struct(); end
    [kbd, mouse] = plv_input_indices(opts);

    % wheels holds one wheel source per row: the device, the path
    % ('buttons', 'axis' or 'getmousewheel') and the incomplete click.
    kq = struct('win', win, 'KeyboardIndex', kbd, 'MouseIndex', mouse, ...
                'hasPTB', have_ptb(), 'shift', false, ...
                'kbdQueues', {{}}, ...
                'wheels', struct('dev', {}, 'path', {}, 'rest', {}), ...
                'wheelPath', 'none', 'wheelReason', '', ...
                'pointerDevice', [], 'buttonDevice', [], ...
                'buttonsQueued', false, 'lastButtons', [0 0 0]);
    plv_warn_once('reset');
    if ~kq.hasPTB
        kq.wheelReason = 'Psychtoolbox is not on the path';
        warning('psychlvgl:NoPTB', ...
                'Psychtoolbox is not on the path; PsychLVGLInput returns neutral input.');
        return;
    end

    % The keyboard queue needs PsychHID, which is not usable on every machine.
    % A panel that cannot read the keyboard is still worth having, so a failure
    % here drops that keyboard rather than stopping the script.
    if isempty(kbd)
        devs = {[]};
    else
        devs = num2cell(kbd);
    end
    msgs = {};
    for k = 1:numel(devs)
        [ok, msg] = plv_keyboard_queue(devs{k});
        if ok
            kq.kbdQueues{end + 1} = devs{k};
        else
            msgs{end + 1} = msg; %#ok<AGROW>
        end
    end
    if isempty(kq.kbdQueues)
        warning('psychlvgl:NoKeyboard', ...
                ['the keyboard queue is not available (%s); the panel runs ' ...
                 'without mouse and keyboard input.'], msgs{1});
        kq.hasPTB = false;
        kq.wheelReason = 'the keyboard queue is not available';
        return;
    end
    if ~isempty(msgs)
        warning('psychlvgl:NoKeyboard', 'a keyboard queue is not available (%s)', ...
                strjoin(msgs, '; '));
    end

    kq = plv_start_wheel(kq);
    kq = plv_start_pointer(kq);
    % The pointer mouse needs polled button rows only when no queue of its
    % own reports the buttons with device time.
    if ~isempty(kq.MouseIndex)
        first = kq.MouseIndex(1);
        for k = 1:numel(kq.wheels)
            if isequal(kq.wheels(k).dev, first) && ~strcmp(kq.wheels(k).path, 'getmousewheel')
                kq.buttonsQueued = true;
            end
        end
    end
end

function [ok, msg] = plv_keyboard_queue(dev)
    ok = false;
    msg = '';
    try
        try
            KbQueueCreate(dev);
        catch
            % A queue already exists on this device, for example from a
            % second panel or from GetChar.
            KbQueueStop(dev);
            KbQueueRelease(dev);
            KbQueueCreate(dev);
        end
        KbQueueStart(dev);
        ok = true;
    catch err
        if isempty(dev)
            msg = err.message;
        else
            msg = sprintf('keyboard %d: %s', dev, err.message);
        end
    end
end

function kq = plv_start_wheel(kq)
% Each branch follows what PsychHID does on that platform; SPEC section 6.2
% has the table and the source file for each row.
    mice = kq.MouseIndex;
    reasons = {};

    if isempty(mice)
        % The Psychtoolbox default: GetMouseWheel, except on Windows, where it
        % does not exist and the one combined mouse carries a queue.
        dev = [];
        if IsWin()
            dev = plv_first_mouse();
        end
        if isempty(dev)
            [kq, reasons] = plv_add_getmousewheel(kq, [], reasons);
        else
            [kq, reasons] = plv_add_wheel(kq, dev, reasons);
        end
    else
        for k = 1:numel(mice)
            [kq, reasons] = plv_add_wheel(kq, mice(k), reasons);
        end
    end
    kq = plv_wheel_summary(kq, reasons);
end

function [kq, reasons] = plv_add_wheel(kq, dev, reasons)
% A queue where the platform has one, else GetMouseWheel on that mouse.
    if IsLinux()
        % X11 reports each wheel click as a raw press and release of button
        % 4 (up), 5 (down), 6 (left) or 7 (right), and PsychHID gives the
        % button number as Keycode. numValuators stays 0: a value of 2 or more
        % also selects every motion event of the mouse, and the scroll
        % valuators in those events count the same clicks a second time.
        % Buttons 1 to 3 are queued too, only for the raw event log.
        keyList = zeros(1, 256);
        keyList(1:7) = 1;
        [ok, reason] = plv_mouse_queue(dev, {keyList, 0});
        path = 'buttons';
    elseif IsWin()
        % GetMouseWheel is not implemented on Windows. A DirectInput mouse
        % queue reports the wheel as the third axis, so numValuators is 3.
        % Flag 4 asks for deltas rather than a running sum. A named mouse
        % also queues buttons 1 to 3 for the raw event log; the default keeps
        % the queue it had, with no buttons.
        keyList = zeros(1, 256);
        if ~isempty(kq.MouseIndex)
            keyList(1:3) = 1;
        end
        [ok, reason] = plv_mouse_queue(dev, {keyList, 3, 10000, 4});
        path = 'axis';
    else
        ok = false;
        reason = '';
    end
    if ok
        kq.wheels(end + 1) = struct('dev', dev, 'path', path, 'rest', 0);
        return;
    end
    if ~isempty(reason); reasons{end + 1} = reason; end
    [kq, reasons] = plv_add_getmousewheel(kq, dev, reasons);
end

function [kq, reasons] = plv_add_getmousewheel(kq, dev, reasons)
% A first call also clears the click count left over from before the panel
% opened.
    try
        if isempty(dev)
            GetMouseWheel();
        else
            GetMouseWheel(dev);
        end
        kq.wheels(end + 1) = struct('dev', dev, 'path', 'getmousewheel', 'rest', 0);
    catch err
        reasons{end + 1} = sprintf('GetMouseWheel failed: %s', err.message);
    end
end

function kq = plv_wheel_summary(kq, reasons)
    kq.wheelReason = strjoin(reasons, '; ');
    if isempty(kq.wheels)
        kq.wheelPath = 'none';
    else
        paths = {kq.wheels.path};
        [~, first] = unique(paths);
        kq.wheelPath = strjoin(paths(sort(first)), '+');
    end
end

function [ok, reason] = plv_mouse_queue(dev, args)
    ok = false;
    reason = '';
    try
        KbQueueCreate(dev, args{:});
        KbQueueStart(dev);
        ok = true;
    catch err
        reason = sprintf('the queue on mouse %d failed: %s', dev, err.message);
        try
            KbQueueRelease(dev);
        catch
            % Nothing was created.
        end
    end
end

function dev = plv_first_mouse()
    dev = [];
    try
        idx = GetMouseIndices();
        if ~isempty(idx)
            dev = idx(1);
        end
    catch
        % PsychHID cannot enumerate; the caller reports no mouse.
    end
end

function kq = plv_start_pointer(kq)
% On Linux, GetMouse(win, slave) returns the slave's own axis values with no
% window offset, because XIQueryPointer works on master pointers only
% (Common/Screen/SCREENGetMouseHelper.c). The position therefore comes from
% the master the slave is attached to: PsychHID reports that attachment as
% locationID and the XInput id as interfaceID. The button still comes from
% the slave, so only the named mouse can click.
    if isempty(kq.MouseIndex)
        return;
    end
    first = kq.MouseIndex(1);
    kq.buttonDevice = first;
    kq.pointerDevice = first;
    if ~IsLinux()
        return;
    end
    try
        [idx, ~, infos] = GetMouseIndices();
    catch
        idx = [];
        infos = {};
    end
    me = find(idx == first, 1);
    if isempty(me)
        kq.pointerDevice = [];
        return;
    end
    info = infos{me};
    if strcmp(plv_field(info, 'usageName', ''), 'master pointer')
        return;
    end
    kq.pointerDevice = [];
    loc = plv_field(info, 'locationID', NaN);
    for k = 1:numel(idx)
        o = infos{k};
        if strcmp(plv_field(o, 'usageName', ''), 'master pointer') && ...
           plv_field(o, 'interfaceID', NaN) == loc
            kq.pointerDevice = idx(k);
            return;
        end
    end
    % A floating slave moves no cursor; GetMouse(win) is the best position.
end

% --- Stop -------------------------------------------------------------------

function do_stop(kq)
    if nargin < 1 || ~isstruct(kq) || ~isfield(kq, 'hasPTB') || ~kq.hasPTB
        return;
    end
    if isfield(kq, 'kbdQueues')
        for k = 1:numel(kq.kbdQueues)
            plv_release(kq.kbdQueues{k});
        end
    end
    if isfield(kq, 'wheels')
        for k = 1:numel(kq.wheels)
            if ~strcmp(kq.wheels(k).path, 'getmousewheel')
                plv_release(kq.wheels(k).dev);
            end
        end
    end
end

function plv_release(dev)
    try
        KbQueueStop(dev);
        KbQueueRelease(dev);
    catch
        % Already stopped, or the queue went with the window.
    end
end

% --- Poll -------------------------------------------------------------------

function [mouse, wheel, keys, kq, events] = do_poll(kq, win, dst, panelW, panelH)
    mouse = [0 0 0];
    wheel = 0;
    keys = zeros(0, 2);
    events = plv_raw_events([]);
    if nargin < 1; kq = []; end

    if nargin < 5 || ~isstruct(kq) || ~kq.hasPTB
        return;
    end
    tPoll = GetSecs();

    [x, y, buttons] = plv_poll_pointer(kq, win);
    pressed = double(~isempty(buttons) && buttons(1) ~= 0);
    sx = panelW / max(1, dst(3) - dst(1));
    sy = panelH / max(1, dst(4) - dst(2));
    mouse = [(x - dst(1)) * sx, (y - dst(2)) * sy, pressed];

    [wheel, kq, wrows] = plv_poll_wheel(kq, tPoll);
    [keys, krows] = plv_poll_keys(kq);
    [kq, brows] = plv_poll_buttons(kq, buttons, tPoll);

    % Rows first and one struct array at the end, because Poll runs every
    % frame and a struct array grown element by element reallocates each time.
    rows = [krows; wrows; brows];
    if size(rows, 1) > 1
        [~, order] = sort(rows(:, 1));   % stable: equal times keep this order
        rows = rows(order, :);
    end
    events = plv_raw_events(rows);
end

function [x, y, buttons] = plv_poll_pointer(kq, win)
    pdev = kq.pointerDevice;
    bdev = kq.buttonDevice;
    if isempty(bdev)
        [x, y, buttons] = GetMouse(win);
    elseif isequal(pdev, bdev)
        [x, y, buttons] = GetMouse(win, bdev);
    else
        if isempty(pdev)
            [x, y] = GetMouse(win);
        else
            [x, y] = GetMouse(win, pdev);
        end
        [~, ~, buttons] = GetMouse(win, bdev);
    end
end

function [kq, rows] = plv_poll_buttons(kq, buttons, tPoll)
% buttons(1:3) are left, middle, right on every path: Windows fills them
% from GetAsyncKeyState, the X core pointer puts buttons 1 to 3 first, and an
% XInput device gives X button k, where 1 to 3 are left, middle, right, in
% buttons(k). Only buttons(1) drives the pointer indev.
    rows = zeros(0, 6);
    b = zeros(1, 3);
    n = min(3, numel(buttons));
    b(1:n) = double(buttons(1:n) ~= 0);
    if ~kq.buttonsQueued
        dev = NaN;
        if ~isempty(kq.buttonDevice); dev = kq.buttonDevice; end
        for c = find(b ~= kq.lastButtons)
            rows(end + 1, :) = [tPoll, dev, 2, c, b(c), 0]; %#ok<AGROW>
        end
    end
    kq.lastButtons = b;
end

function [keys, rows] = plv_poll_keys(kq)
% With one keyboard the queue is already in time order. With several, the
% events are merged by Time first, so a key typed on one keyboard cannot
% jump ahead of an earlier key on another.
    keys = zeros(0, 2);
    evts = {};
    devs = zeros(1, 0);
    times = zeros(1, 0);
    for k = 1:numel(kq.kbdQueues)
        dev = kq.kbdQueues{k};
        while KbEventAvail(dev)
            evt = KbEventGet(dev);
            if isempty(evt); break; end
            evts{end + 1} = evt; %#ok<AGROW>
            times(end + 1) = plv_field(evt, 'Time', 0); %#ok<AGROW>
            if isempty(dev); devs(end + 1) = NaN; else; devs(end + 1) = dev; end %#ok<AGROW>
        end
    end
    if numel(kq.kbdQueues) > 1
        [~, order] = sort(times);   % stable, so equal times keep queue order
        evts = evts(order);
        devs = devs(order);
        times = times(order);
    end
    rows = zeros(numel(evts), 6);
    for k = 1:numel(evts)
        e = evts{k};
        rows(k, :) = [times(k), devs(k), 1, plv_field(e, 'Keycode', 0), ...
                      plv_field(e, 'Pressed', 0), plv_field(e, 'CookedKey', 0)];
        row = PsychLVGLKeyMap(e, kq.shift);
        if ~isempty(row)
            keys(end + 1, :) = row; %#ok<AGROW>
        end
    end
end

function [wheel, kq, rows] = plv_poll_wheel(kq, tPoll)
    wheel = 0;
    rows = zeros(0, 6);
    if isempty(kq.wheels)
        plv_warn_once(plv_or(kq.wheelReason, 'no wheel source'));
        return;
    end
    if ~isempty(kq.wheelReason)
        % Some mice work and some do not; say which once.
        plv_warn_once(kq.wheelReason);
    end
    for k = 1:numel(kq.wheels)
        [clicks, kq.wheels(k), r] = plv_poll_one_wheel(kq.wheels(k), tPoll);
        wheel = wheel + clicks;
        rows = [rows; r]; %#ok<AGROW>
    end
end

function [clicks, w, rows] = plv_poll_one_wheel(w, tPoll)
    clicks = 0;
    rows = zeros(0, 6);
    dev = w.dev;
    if isempty(dev); dev = NaN; end
    try
        switch w.path
            case 'buttons'
                % Only presses count. X11 sends a release after every press.
                % Buttons 6 and 7 are the horizontal wheel, which the one-axis
                % encoder has no use for; they go to the log only. Buttons 1
                % to 3 go to the log as button rows and nowhere else.
                while KbEventAvail(w.dev)
                    evt = KbEventGet(w.dev);
                    if isempty(evt); break; end
                    code = plv_field(evt, 'Keycode', 0);
                    p = double(plv_field(evt, 'Pressed', 0) ~= 0);
                    t = plv_field(evt, 'Time', tPoll);
                    if code >= 1 && code <= 3
                        rows(end + 1, :) = [t, dev, 2, code, p, 0]; %#ok<AGROW>
                    elseif p
                        switch code
                            case 4; c = [1 1];
                            case 5; c = [1 -1];
                            case 6; c = [2 -1];
                            case 7; c = [2 1];
                            otherwise; c = [];
                        end
                        if ~isempty(c)
                            rows(end + 1, :) = [t, dev, 3, c(1), c(2), 0]; %#ok<AGROW>
                            if c(1) == 1; clicks = clicks + c(2); end
                        end
                    end
                end
            case 'axis'
                % DirectInput gives 120 units for each click (WHEEL_DELTA). A
                % high resolution wheel sends smaller steps, so the part of a
                % click that is not complete waits in w.rest. Each event
                % completes its clicks at once, so the log rows add up to the
                % wheel value. DirectInput numbers the buttons left, right,
                % middle; the log uses left, middle, right.
                btnCode = [1 3 2];
                while KbEventAvail(w.dev)
                    evt = KbEventGet(w.dev);
                    if isempty(evt); break; end
                    t = plv_field(evt, 'Time', tPoll);
                    v = plv_field(evt, 'Valuators', []);
                    if plv_field(evt, 'Type', 0) == 1
                        if numel(v) >= 3 && v(3) ~= 0
                            w.rest = w.rest + v(3);
                            c = fix(w.rest / 120);
                            if c ~= 0
                                w.rest = w.rest - 120 * c;
                                clicks = clicks + c;
                                rows(end + 1, :) = [t, dev, 3, 1, c, 0]; %#ok<AGROW>
                            end
                        end
                    else
                        code = plv_field(evt, 'Keycode', 0);
                        if code >= 1 && code <= 3
                            p = double(plv_field(evt, 'Pressed', 0) ~= 0);
                            rows(end + 1, :) = [t, dev, 2, btnCode(code), p, 0]; %#ok<AGROW>
                        end
                    end
                end
            case 'getmousewheel'
                if isempty(w.dev)
                    clicks = GetMouseWheel();
                else
                    clicks = GetMouseWheel(w.dev);
                end
                if isempty(clicks); clicks = 0; end
                if clicks ~= 0
                    rows = [tPoll, dev, 3, 1, clicks, 0];
                end
        end
    catch err
        % A wheel that stops working must not stop the experiment.
        clicks = 0;
        rows = zeros(0, 6);
        plv_warn_once(sprintf('wheel path "%s" failed: %s', w.path, err.message));
    end
end

% --- Devices ----------------------------------------------------------------

function d = do_devices()
    d = struct('keyboards', plv_dev_list([], {}, {}), 'mice', plv_dev_list([], {}, {}));
    if ~have_ptb()
        fprintf('Psychtoolbox is not on the path; no devices to list.\n');
        return;
    end
    try
        [ki, kn, kinfo] = GetKeyboardIndices();
        d.keyboards = plv_dev_list(ki, kn, kinfo);
    catch err
        fprintf('GetKeyboardIndices failed: %s\n', err.message);
    end
    try
        [mi, mn, minfo] = GetMouseIndices();
        d.mice = plv_dev_list(mi, mn, minfo);
    catch err
        fprintf('GetMouseIndices failed: %s\n', err.message);
    end
    plv_print_devices('Keyboards (opts.KeyboardIndex)', d.keyboards);
    plv_print_devices('Mice (opts.MouseIndex)', d.mice);
end

function s = plv_dev_list(idx, names, infos)
    s = struct('index', {}, 'product', {}, 'usageName', {}, ...
               'xinputName', {}, 'xinputId', {});
    if isempty(idx); return; end
    linux = IsLinux();
    for k = 1:numel(idx)
        info = struct();
        if k <= numel(infos) && isstruct(infos{k}); info = infos{k}; end
        product = '';
        if k <= numel(names) && ischar(names{k}); product = names{k}; end
        e.index = double(idx(k));
        e.product = product;
        e.usageName = plv_field(info, 'usageName', '');
        if linux
            % PsychHID on Linux fills product with the XInput device name
            % and interfaceID with the XInput device id.
            e.xinputName = plv_field(info, 'product', product);
            e.xinputId = double(plv_field(info, 'interfaceID', NaN));
        else
            e.xinputName = '';
            e.xinputId = NaN;
        end
        s(end + 1) = e; %#ok<AGROW>
    end
end

function plv_print_devices(title, s)
    fprintf('%s:\n', title);
    if isempty(s)
        fprintf('  none\n');
        return;
    end
    for k = 1:numel(s)
        if isnan(s(k).xinputId)
            fprintf('  %3d  %-40s %s\n', s(k).index, s(k).product, s(k).usageName);
        else
            fprintf('  %3d  %-40s %-16s xinput id %d\n', s(k).index, s(k).product, ...
                    s(k).usageName, s(k).xinputId);
        end
    end
end

% --- helpers ----------------------------------------------------------------

function v = plv_field(s, name, default)
    if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    else
        v = default;
    end
end

function s = plv_or(s, default)
    if isempty(s); s = default; end
end

function plv_warn_once(reason)
% Poll runs every frame, and a warning each frame would bury the command
% window. One warning per reason per Start is enough to name the cause.
    persistent seen
    if strcmp(reason, 'reset')
        seen = {};
        return;
    end
    if isempty(seen); seen = {}; end
    if any(strcmp(seen, reason)); return; end
    seen{end + 1} = reason;
    warning('psychlvgl:NoWheel', 'the mouse wheel is not available (%s); the wheel reads as zero.', reason);
end

function tf = have_ptb()
    tf = exist('Screen', 'file') ~= 0 && exist('KbQueueCreate', 'file') ~= 0;
end
