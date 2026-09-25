function test_input()
% TEST_INPUT  Device selection and the wheel paths of PsychLVGLInput.
%
%   Runs against tests/stub, where plv_stub_input holds the state of the
%   Psychtoolbox input stubs and can pretend to be any platform. Nothing here
%   touches the path (SPEC D35). A real test with several mice and a real
%   wheel needs the lab machine; SPEC section 6.2 lists what these stubs
%   stand in for.

    plv_assert('the stub input layer is on the path', ...
               ~isempty(strfind(which('plv_stub_input'), 'stub'))); %#ok<STREMP>

    t_default();
    t_linux_start();
    t_linux_poll();
    t_pointer();
    t_multi();
    t_raw();
    t_windows();
    t_mac();
    t_missing_wheel();
    t_usage();
    t_devices();
    t_open_frame();

    plv_stub_input('reset');
end

% --- the empty default ------------------------------------------------------

function t_default()
% No indices: the Psychtoolbox default keyboard queue, GetMouse(win) and
% GetMouseWheel(), with nothing else.
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct());
    plv_eq('the default keeps KeyboardIndex empty', kq.KeyboardIndex, []);
    plv_eq('the default keeps MouseIndex empty', kq.MouseIndex, []);
    plv_eq('the default creates one queue, on the default keyboard', calls('KbQueueCreate'), {{[]}});
    plv_eq('the default wheel is GetMouseWheel()', kq.wheelPath, 'getmousewheel');
    plv_eq('GetMouseWheel gets no device', calls('GetMouseWheel'), {{}});
    plv_stub_input('wheel', -1);
    plv_stub_input('push', [], struct('Keycode', 66, 'CookedKey', 98, 'Pressed', 1, 'Time', 1));
    [~, wheel, keys] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('the default reads the pointer with GetMouse(win)', calls('GetMouse'), {{1}});
    plv_eq('the default wheel passes through', wheel, -1);
    plv_eq('the default keyboard gives its key', keys, [98 1]);
    plv_eq('GetMouseIndices is not called', numel(calls('GetMouseIndices')), 0);
    PsychLVGLInput('Stop', kq);
    plv_eq('Stop releases the default queue only', calls('KbQueueRelease'), {{[]}});
end

% --- Linux: two queues, wheel as buttons 4 and 5 -----------------------------

function t_linux_start()
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct('KeyboardIndex', 4, 'MouseIndex', 7));

    plv_eq('Start keeps KeyboardIndex', kq.KeyboardIndex, 4);
    plv_eq('Start keeps MouseIndex', kq.MouseIndex, 7);
    plv_eq('Linux with MouseIndex reads the wheel as buttons', kq.wheelPath, 'buttons');

    c = calls('KbQueueCreate');
    plv_eq('Start creates two queues', numel(c), 2);
    plv_eq('the keyboard queue is on KeyboardIndex', c{1}, {4});
    plv_eq('the mouse queue is on MouseIndex', c{2}{1}, 7);
    keyList = c{2}{2};
    plv_eq('the mouse keyList has 256 entries', numel(keyList), 256);
    plv_eq('the mouse keyList holds buttons 1 to 7 only', find(keyList), 1:7);
    plv_eq('the mouse queue asks for no valuators', c{2}{3}, 0);
    s = calls('KbQueueStart');
    plv_eq('both queues are started', s, {{4}, {7}});
    plv_eq('GetMouseWheel is not used when the queue works', numel(calls('GetMouseWheel')), 0);

    PsychLVGLInput('Stop', kq);
    plv_eq('Stop releases the keyboard queue and the mouse queue', ...
           calls('KbQueueRelease'), {{4}, {7}});
end

function t_linux_poll()
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct('KeyboardIndex', 4, 'MouseIndex', 7));

    % Two clicks down: X11 sends a press and a release for each click.
    plv_stub_input('push', 7, btn(5, 1));
    plv_stub_input('push', 7, btn(5, 0));
    plv_stub_input('push', 7, btn(5, 1));
    plv_stub_input('push', 7, btn(5, 0));
    plv_stub_input('push', 4, struct('Keycode', 65, 'CookedKey', 97, 'Pressed', 1));

    [mouse, wheel, keys, kq] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('two presses of button 5 are a wheel of -2', wheel, -2);
    plv_assert('Poll returns the mouse row', numel(mouse) == 3);
    plv_eq('the keyboard queue gives its key', keys, [97 1]);
    plv_eq('the mouse queue is drained', plv_stub_input('avail', 7), 0);
    g = calls('GetMouse');
    plv_eq('the position comes from the master of MouseIndex', g{end - 1}, {1, 2});
    plv_eq('the button comes from MouseIndex', g{end}, {1, 7});

    % Button 4 is up, and releases do not count.
    plv_stub_input('push', 7, btn(4, 1));
    plv_stub_input('push', 7, btn(4, 0));
    [~, wheel, keys, kq] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('one press of button 4 is a wheel of +1', wheel, 1);
    plv_assert('no wheel event reaches the keys', isempty(keys));

    % The encoder has one axis, so horizontal clicks are dropped, and the
    % left and right buttons never become keys.
    plv_stub_input('push', 7, btn(6, 1));
    plv_stub_input('push', 7, btn(7, 1));
    plv_stub_input('push', 7, btn(1, 1));
    [~, wheel, keys] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('buttons 6 and 7 are ignored', wheel, 0);
    plv_assert('mouse buttons never reach the keypad', isempty(keys));

    % The sign reaches the MEX as SPEC 6.2 says: WheelMode 'keys' turns a
    % wheel of -2 into two LV_KEY_DOWN presses, which move a focused roller
    % down two rows. This is the software variant of the MEX.
    PsychLVGL('Init', 200, 200, struct('WheelMode', 'keys'));
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>
    scr = PsychLVGL('ScreenActive');
    roller = PsychLVGL('RollerCreate', scr);
    PsychLVGL('RollerSetOptions', roller, sprintf('a\nb\nc\nd'), 'LV_ROLLER_MODE_NORMAL');
    PsychLVGL('AddToGroup', roller);
    PsychLVGL('FocusObj', roller);
    PsychLVGL('Update', 10, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Update', 10.1, [0 0 0], -2, zeros(0, 2));
    plv_eq('a wheel of -2 moves the roller down two rows', ...
           PsychLVGL('RollerGetSelected', roller), 2);
end

% --- pointer position with a slave MouseIndex -------------------------------

function t_pointer()
    % GetMouse on a slave returns raw axes; the master gives window
    % coordinates. Only button 1 of the slave counts, so another mouse on
    % the same master cannot click.
    plv_stub_input('reset');
    plv_stub_input('mouse', 2, 50, 60, [1 0 0]);
    plv_stub_input('mouse', 7, 9000, 9000, [0 0 0 1 0]);
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 7));
    plv_eq('the master of mouse 7 is found', kq.pointerDevice, 2);
    mouse = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('position from the master, button from the slave', mouse, [50 60 0]);
    plv_stub_input('mouse', 7, 9000, 9000, [1 0 0 0 0]);
    mouse = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('button 1 of the slave presses', mouse, [50 60 1]);

    % A master named directly needs one call.
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 2));
    plv_eq('a master pointer is its own pointer device', kq.pointerDevice, 2);
    PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('a master takes one GetMouse call', calls('GetMouse'), {{1, 2}});

    % A floating slave has no master; the core pointer gives the position.
    plv_stub_input('reset');
    plv_stub_input('mouseInfo', {'master pointer', 'floating slave', 'slave pointer'}, [2 10 11], [3 0 2]);
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 7));
    plv_eq('a floating slave has no pointer device', kq.pointerDevice, []);
    PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('the position then comes from GetMouse(win)', calls('GetMouse'), {{1}, {1, 7}});
end

% --- several keyboards and mice ----------------------------------------------

function t_multi()
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct('KeyboardIndex', [0 4], 'MouseIndex', [7 9]));
    plv_eq('KeyboardIndex keeps the array', kq.KeyboardIndex, [0 4]);
    plv_eq('MouseIndex keeps the array', kq.MouseIndex, [7 9]);
    plv_eq('one queue per device', first_args(calls('KbQueueCreate')), [0 4 7 9]);
    plv_eq('both mice read the wheel as buttons', kq.wheelPath, 'buttons');

    % Interleaved times: a from 0 at t=1, b from 4 at t=2, c from 0 at t=3,
    % d from 4 at t=4. Each queue is in order; the merge must interleave.
    plv_stub_input('push', 0, key('a', 1));
    plv_stub_input('push', 0, key('c', 3));
    plv_stub_input('push', 4, key('b', 2));
    plv_stub_input('push', 4, key('d', 4));
    % Two clicks down on mouse 7, one up and one down on mouse 9.
    plv_stub_input('push', 7, btn(5, 1));
    plv_stub_input('push', 7, btn(5, 1));
    plv_stub_input('push', 9, btn(4, 1));
    plv_stub_input('push', 9, btn(5, 1));
    [~, wheel, keys, kq] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('keys from two keyboards merge in time order', keys(:, 1)', double('abcd'));
    plv_eq('clicks from two mice add up', wheel, -2);
    g = calls('GetMouse');
    plv_eq('the pointer follows the first mouse', g(end - 1:end), {{1, 2}, {1, 7}});

    PsychLVGLInput('Stop', kq);
    plv_eq('Stop releases every queue', first_args(calls('KbQueueRelease')), [0 4 7 9]);

    % Windows: one axis queue per mouse, summed.
    plv_stub_input('reset');
    plv_stub_input('platform', 'windows');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', [7 9]));
    plv_stub_input('push', 7, axis_evt([0 0 120]));
    plv_stub_input('push', 9, axis_evt([0 0 240]));
    [~, wheel] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('Windows clicks from two mice add up', wheel, 3);

    % One mouse without a wheel does not hide the other.
    plv_stub_input('reset');
    plv_stub_input('createError', 9, 'Invalid deviceIndex');
    plv_stub_input('wheelError', 'Given mouse does not have a wheel.');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', [7 9]));
    plv_eq('the working mouse keeps its queue', [kq.wheels.dev], 7);
    plv_stub_input('push', 7, btn(4, 1));
    lastwarn('');
    [~, wheel] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    [msg, id] = lastwarn();
    plv_eq('the working mouse still scrolls', wheel, 1);
    plv_eq('the broken mouse warns', id, 'psychlvgl:NoWheel');
    plv_assert('the warning names the mouse', ~isempty(strfind(msg, 'mouse 9'))); %#ok<STREMP>
end

% --- the raw device log -----------------------------------------------------

function t_raw()
    % Two keyboards: rows in time order with their device indices.
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct('KeyboardIndex', [0 4], 'MouseIndex', [7 9]));
    plv_stub_input('push', 0, key('a', 1.0, 65));
    plv_stub_input('push', 0, key('c', 3.0, 67));
    plv_stub_input('push', 4, key('b', 2.0, 66));
    % Wheel: two down on mouse 7, one up on mouse 9, one left on mouse 9.
    plv_stub_input('push', 7, btn(5, 1, 5.0));
    plv_stub_input('push', 7, btn(5, 0, 5.1));
    plv_stub_input('push', 7, btn(5, 1, 6.0));
    plv_stub_input('push', 9, btn(4, 1, 5.5));
    plv_stub_input('push', 9, btn(6, 1, 7.0));
    [~, wheel, keys, kq, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    k = ev(ev(:, 3) == 1, :);
    plv_eq('key rows are in time order', k(:, 1)', [1 2 3]);
    plv_eq('key rows carry the device index', k(:, 2)', [0 4 0]);
    plv_eq('key rows carry the PTB keycode', k(:, 4)', [65 66 67]);
    plv_eq('key rows carry CookedKey', k(:, 6)', double('abc'));
    plv_eq('keys still reach the keypad', keys(:, 1)', double('abc'));
    plv_assert('the whole log is in time order', issorted(ev(:, 1)));
    v = ev(ev(:, 3) == 3 & ev(:, 4) == 1, :);
    plv_eq('vertical wheel rows add up to the wheel', sum(v(:, 5)), wheel);
    plv_eq('the wheel is -1', wheel, -1);
    plv_eq('one row per click, with the device time', v(:, [1 2 5]), [5 7 -1; 5.5 9 1; 6 7 -1]);
    h = ev(ev(:, 3) == 3 & ev(:, 4) == 2, :);
    plv_eq('a left click is a horizontal row of -1', h(:, [1 2 5]), [7 9 -1]);

    % Buttons through the Linux queue: device time, never keys or wheel.
    plv_stub_input('push', 7, btn(1, 1, 10.0));
    plv_stub_input('push', 7, btn(1, 0, 10.25));
    plv_stub_input('push', 7, btn(3, 1, 10.5));
    plv_stub_input('mouse', 7, 0, 0, [1 0 0]);
    [~, wheel, keys, kq, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100); %#ok<ASGLU>
    plv_eq('queued button rows carry device times', ev, ...
           [10 7 2 1 1 0; 10.25 7 2 1 0 0; 10.5 7 2 3 1 0]);
    plv_eq('buttons do not turn the wheel', wheel, 0);
    plv_assert('buttons do not reach the keys', isempty(keys));

    % Windows: DirectInput numbers left, right, middle; the log uses left,
    % middle, right. A named mouse queues buttons 1 to 3.
    plv_stub_input('reset');
    plv_stub_input('platform', 'windows');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 9));
    c = calls('KbQueueCreate');
    plv_eq('a named Windows mouse queues buttons 1 to 3', find(c{2}{2}), 1:3);
    plv_stub_input('push', 9, btn(2, 1, 20.0));
    plv_stub_input('push', 9, axis_evt([0 0 240], 20.5));
    [~, wheel, ~, ~, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('DirectInput button 2 is the right button', ev(1, :), [20 9 2 3 1 0]);
    plv_eq('an axis event that completes two clicks is one row', ev(2, :), [20.5 9 3 1 2 0]);
    plv_eq('and the wheel agrees', wheel, 2);

    % The default: no mouse queue, so button rows come from GetMouse changes
    % at poll time, and the default keyboard is NaN.
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct());
    plv_stub_input('mouse', [], 0, 0, [1 0 0]);
    plv_stub_input('push', [], key('x', 30.0, 88));
    [~, ~, ~, kq, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    b = ev(ev(:, 3) == 2, :);
    plv_eq('a polled press is one row from the default mouse', b(:, 2:6), [NaN 2 1 1 0]);
    plv_assert('a polled row carries the poll time', b(1, 1) > 30);
    k = ev(ev(:, 3) == 1, :);
    plv_eq('the default keyboard is NaN', k(:, [1 2 4]), [30 NaN 88]);
    [~, ~, ~, kq, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_assert('a held button gives no new row', isempty(ev));
    plv_stub_input('mouse', [], 0, 0, [0 0 1]);
    [~, ~, ~, ~, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('a release and a right press are two rows', ev(:, 4:5), [1 0; 3 1]);

    % The same with a named mouse whose queue fails: polled rows, with the
    % device index.
    plv_stub_input('reset');
    plv_stub_input('platform', 'mac');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 7));
    plv_stub_input('mouse', 7, 0, 0, [1 0 0]);
    [~, ~, ~, ~, ev] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('macOS buttons are polled from MouseIndex', ev(:, 2:5), [7 2 1 1]);

    % The decode and filter helpers.
    raw = [1 0 1 65 1 97; 2 7 2 1 1 0; 3 7 3 1 -2 0; 4 NaN 2 3 0 0];
    S = PsychLVGLEvents('decodeRaw', raw);
    plv_eq('decodeRaw gives one struct per row', size(S), [4 1]);
    plv_eq('decodeRaw fields', fieldnames(S)', ...
           {'time', 'device', 'kind', 'kindName', 'code', 'name', 'pressed', 'cooked'});
    plv_eq('decodeRaw kind names', {S.kindName}, {'key', 'button', 'wheel', 'button'});
    plv_eq('decodeRaw button name', S(2).name, 'left');
    plv_eq('decodeRaw wheel name', S(3).name, 'vertical');
    plv_eq('decodeRaw keeps the signed clicks', S(3).pressed, -2);
    plv_eq('decodeRaw keeps cooked', S(1).cooked, 97);
    E0 = PsychLVGLEvents('decodeRaw', zeros(0, 6));
    plv_assert('decodeRaw of nothing is empty', isempty(E0) && isstruct(E0));
    plv_eq('filterRaw by kind name', PsychLVGLEvents('filterRaw', raw, 'button'), raw([2 4], :));
    plv_eq('filterRaw by button name', PsychLVGLEvents('filterRaw', raw, 'button', 'right'), raw(4, :));
    plv_eq('filterRaw by keycode', PsychLVGLEvents('filterRaw', raw, 1, 65), raw(1, :));
    plv_eq('filterRaw with nothing constrained', PsychLVGLEvents('filterRaw', raw), raw);
    plv_throws('decodeRaw wants six columns', 'psychlvgl:Usage', ...
               @() PsychLVGLEvents('decodeRaw', zeros(2, 5)));
end

% --- Windows: one DirectInput mouse, wheel as the third axis ----------------

function t_windows()
    plv_stub_input('reset');
    plv_stub_input('platform', 'windows');
    kq = PsychLVGLInput('Start', 1, struct());

    plv_eq('Windows reads the wheel as an axis', kq.wheelPath, 'axis');
    plv_eq('with no MouseIndex, the first mouse carries the queue', kq.wheels(1).dev, 2);
    c = calls('KbQueueCreate');
    plv_eq('the keyboard queue is the default one', c{1}, {[]});
    plv_eq('the mouse queue asks for three valuators, raw deltas', ...
           c{2}, {2, zeros(1, 256), 3, 10000, 4});

    plv_stub_input('push', 2, axis_evt([0 0 -120]));
    plv_stub_input('push', 2, axis_evt([4 -3 0]));
    plv_stub_input('push', 2, axis_evt([0 0 -120]));
    plv_stub_input('push', 2, btn(1, 1));
    [~, wheel, keys, kq] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('two -120 steps are a wheel of -2', wheel, -2);
    plv_assert('Windows mouse events never reach the keys', isempty(keys));

    plv_stub_input('push', 2, axis_evt([0 0 60]));
    [~, wheel, ~, kq] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('half a click waits', wheel, 0);
    plv_stub_input('push', 2, axis_evt([0 0 60]));
    [~, wheel] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('the second half completes the click', wheel, 1);

    plv_stub_input('reset');
    plv_stub_input('platform', 'windows');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 9));
    plv_eq('Windows uses MouseIndex when it is set', kq.wheels(1).dev, 9);
    PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('Windows reads the pointer with one GetMouse call', calls('GetMouse'), {{1, 9}});
end

% --- macOS: GetMouseWheel on MouseIndex -------------------------------------

function t_mac()
    plv_stub_input('reset');
    plv_stub_input('platform', 'mac');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 7));
    plv_eq('macOS reads the wheel with GetMouseWheel', kq.wheelPath, 'getmousewheel');
    plv_eq('macOS creates only the keyboard queue', numel(calls('KbQueueCreate')), 1);
    plv_stub_input('wheel', 3);
    [~, wheel] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    plv_eq('GetMouseWheel clicks pass through', wheel, 3);
    g = calls('GetMouseWheel');
    plv_eq('GetMouseWheel reads MouseIndex', g{end}, {7});
end

% --- no wheel ---------------------------------------------------------------

function t_missing_wheel()
    plv_stub_input('reset');
    plv_stub_input('wheelError', 'GetMouseWheel could not find any mice with mouse wheels');
    kq = PsychLVGLInput('Start', 1, struct());
    plv_eq('no wheel source gives the path none', kq.wheelPath, 'none');

    lastwarn('');
    [~, wheel, ~, kq] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    [msg, id] = lastwarn();
    plv_eq('a missing wheel reads as zero', wheel, 0);
    plv_eq('the first Poll warns', id, 'psychlvgl:NoWheel');
    plv_assert('the warning names the reason', ~isempty(strfind(msg, 'could not find'))); %#ok<STREMP>
    lastwarn('');
    [~, wheel] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    [~, id] = lastwarn();
    plv_eq('the second Poll is quiet', id, '');
    plv_eq('and still reads zero', wheel, 0);

    % A Linux mouse queue that fails falls back to GetMouseWheel, and both
    % reasons reach the warning.
    plv_stub_input('reset');
    plv_stub_input('createError', 7, 'Invalid deviceIndex');
    plv_stub_input('wheelError', 'Given mouse does not have a wheel.');
    kq = PsychLVGLInput('Start', 1, struct('MouseIndex', 7));
    plv_eq('a failed queue and a failed GetMouseWheel give none', kq.wheelPath, 'none');
    plv_assert('the reason names the queue', ~isempty(strfind(kq.wheelReason, 'queue on mouse 7'))); %#ok<STREMP>

    % GetMouseWheel that starts to fail after Start must not stop Poll.
    plv_stub_input('reset');
    kq = PsychLVGLInput('Start', 1, struct());
    plv_stub_input('wheelError', 'PsychHID went away');
    lastwarn('');
    [~, wheel] = PsychLVGLInput('Poll', kq, 1, [0 0 100 100], 100, 100);
    [~, id] = lastwarn();
    plv_eq('a failing GetMouseWheel reads as zero', wheel, 0);
    plv_eq('and warns', id, 'psychlvgl:NoWheel');
end

% --- argument checks --------------------------------------------------------

function t_usage()
    plv_stub_input('reset');
    plv_throws('equal indices are refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('KeyboardIndex', 3, 'MouseIndex', 3)));
    plv_throws('a negative index is refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('MouseIndex', -1)));
    plv_throws('a char index is refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('KeyboardIndex', 'kbd')));
    plv_throws('a matrix index is refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('KeyboardIndex', [1 2; 3 5])));
    plv_throws('a keyboard listed twice is refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('KeyboardIndex', [0 4 0])));
    plv_throws('a mouse listed twice is refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('MouseIndex', [7 7])));
    plv_throws('a device in both lists is refused', 'psychlvgl:Usage', ...
               @() PsychLVGLInput('Start', 1, struct('KeyboardIndex', [0 4], 'MouseIndex', [7 4])));
    plv_eq('no queue was created for bad options', numel(calls('KbQueueCreate')), 0);
end

% --- Devices ----------------------------------------------------------------

function t_devices()
    plv_stub_input('reset');
    d = PsychLVGLInput('Devices');
    plv_assert('Devices returns a struct', isstruct(d) && isscalar(d));
    plv_assert('with keyboards and mice', isfield(d, 'keyboards') && isfield(d, 'mice'));
    names = {'index', 'product', 'usageName', 'xinputName', 'xinputId'};
    plv_eq('keyboard entries have the five fields', fieldnames(d.keyboards)', names);
    plv_eq('mouse entries have the five fields', fieldnames(d.mice)', names);
    plv_eq('two keyboards', [d.keyboards.index], [0 4]);
    plv_eq('three mice', [d.mice.index], [2 7 9]);
    plv_eq('the product name is char', d.mice(2).product, 'Logitech USB Optical Mouse');
    plv_eq('Linux gives the XInput name', d.mice(2).xinputName, 'Logitech USB Optical Mouse');
    plv_eq('Linux gives the XInput id', d.mice(2).xinputId, 10);
    plv_eq('Linux gives the device use', d.mice(2).usageName, 'slave pointer');
    plv_assert('every field is char or double', all_char_or_double(d));

    plv_stub_input('platform', 'windows');
    d = PsychLVGLInput('Devices');
    plv_eq('other platforms have no XInput name', d.mice(1).xinputName, '');
    plv_assert('and no XInput id', isnan(d.mice(1).xinputId));

    plv_stub_input('devices', [], {}, [], {});
    d = PsychLVGLInput('Devices');
    plv_assert('no devices gives empty lists', isempty(d.keyboards) && isempty(d.mice));
    plv_eq('an empty list keeps the fields', fieldnames(d.mice)', names);
end

% --- through PsychLVGLOpen and PsychLVGLFrame --------------------------------

function t_open_frame()
    plv_stub_input('reset');
    Screen('stubReset');
    plv_throws('Open refuses equal indices', 'psychlvgl:Usage', ...
               @() PsychLVGLOpen(1, 64, 48, [], struct('KeyboardIndex', 7, 'MouseIndex', 7)));
    plv_throws('Open refuses a duplicate', 'psychlvgl:Usage', ...
               @() PsychLVGLOpen(1, 64, 48, [], struct('MouseIndex', [7 9 7])));
    plv_eq('the refused Open never entered 3D mode', Screen('stubBeginDepth'), 0);

    ui = PsychLVGLOpen(1, 64, 48, [], struct('KeyboardIndex', 4, 'MouseIndex', 7));
    plv_eq('Open passes KeyboardIndex to Start', ui.kq.KeyboardIndex, 4);
    plv_eq('Open passes MouseIndex to Start', ui.kq.MouseIndex, 7);
    plv_eq('ui shows KeyboardIndex', ui.KeyboardIndex, 4);
    plv_eq('ui shows MouseIndex', ui.MouseIndex, 7);
    plv_stub_input('push', 7, btn(5, 1));
    [ui, E, events] = PsychLVGLFrame(ui); %#ok<ASGLU>
    plv_eq('Frame stores the raw log in ui.events', ui.events, events);
    plv_eq('the raw log has six columns', size(events, 2), 6);
    g = calls('GetMouse');
    plv_eq('Frame reads the button on MouseIndex', g{end}, {1, 7});
    plv_eq('Frame drained the mouse queue', plv_stub_input('avail', 7), 0);
    PsychLVGLClose(ui);
    r = calls('KbQueueRelease');
    plv_eq('Close releases both queues', r(end - 1:end), {{4}, {7}});
end

% --- helpers ----------------------------------------------------------------

function c = calls(name)
    log = plv_stub_input('log');
    c = {};
    for k = 1:numel(log)
        if strcmp(log(k).name, name)
            c{end + 1} = log(k).args; %#ok<AGROW>
        end
    end
end

function e = btn(code, pressed, t)
% The fields PsychHID returns for a button event (Type 0).
    if nargin < 3; t = 0; end
    e = struct('Type', 0, 'Time', t, 'Pressed', pressed, 'Keycode', code, ...
               'CookedKey', -1, 'ButtonStates', 0, 'Motion', 0, 'X', 0, 'Y', 0, ...
               'NormX', 0, 'NormY', 0, 'Valuators', zeros(1, 0));
end

function v = first_args(c)
    v = zeros(1, numel(c));
    for k = 1:numel(c)
        v(k) = c{k}{1};
    end
end

function e = key(ch, t, code)
    if nargin < 3; code = 0; end
    e = struct('Type', 0, 'Time', t, 'Pressed', 1, 'Keycode', code, ...
               'CookedKey', double(ch), 'ButtonStates', 0, 'Motion', 0, 'X', 0, 'Y', 0, ...
               'NormX', 0, 'NormY', 0, 'Valuators', zeros(1, 0));
end

function e = axis_evt(v, t)
% A Windows DirectInput mouse axis event (Type 1) with raw deltas.
    if nargin < 2; t = 0; end
    e = struct('Type', 1, 'Time', t, 'Pressed', 0, 'Keycode', 0, ...
               'CookedKey', -1, 'ButtonStates', 0, 'Motion', 1, 'X', 0, 'Y', 0, ...
               'NormX', 0, 'NormY', 0, 'Valuators', v);
end

function tf = all_char_or_double(d)
    tf = true;
    lists = {d.keyboards, d.mice};
    for i = 1:numel(lists)
        s = lists{i};
        f = fieldnames(s);
        for k = 1:numel(s)
            for j = 1:numel(f)
                v = s(k).(f{j});
                tf = tf && (ischar(v) || isa(v, 'double'));
            end
        end
    end
end
