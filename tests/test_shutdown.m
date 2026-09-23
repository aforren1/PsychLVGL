function test_shutdown()
% TEST_SHUTDOWN  Shutdown deletes every screen the session registered and
%   then its resources, without touching a freed object.
%
%   The first cycle is the exact path that crashed on Linux and macOS in
%   phase 2: ScreenActive registers the active screen, so the old code freed
%   it inside its slot loop and then read it again. The Windows heap left the
%   memory readable, so on Windows this passes either way; the suite has to
%   run on Linux or macOS to catch a regression.

    for cycle = 1:3
        PsychLVGL('Init', 120, 80);
        scr = PsychLVGL('ScreenActive');
        box = PsychLVGL('ObjCreate', scr);
        PsychLVGL('ObjSetSize', box, 40, 30);
        PsychLVGL('Update', 100 + cycle, [0 0 0], 0, zeros(0, 2));
        PsychLVGL('Shutdown');
        plv_assert(sprintf('cycle %d: Shutdown after ScreenActive returns', cycle), true);
    end

    % an unloaded screen with a child, a styled active screen, a chart that
    % owns a series, and the old screen loaded away before Shutdown
    PsychLVGL('Init', 120, 80);
    scr = PsychLVGL('ScreenActive');
    other = PsychLVGL('ScreenCreate');
    kid = PsychLVGL('LabelCreate', other);
    st = PsychLVGL('StyleCreate');
    PsychLVGL('StyleSetProp', st, 'bg_color', [0 128 0]);
    PsychLVGL('ObjAddStyle', scr, st);
    ch = PsychLVGL('ChartCreate', scr);
    ser = PsychLVGL('ChartAddSeries', ch, [255 0 0], 0);
    PsychLVGL('Update', 200, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Shutdown');

    PsychLVGL('Init', 120, 80);
    plv_assert('the unloaded screen is gone', ~PsychLVGL('IsValid', other));
    plv_assert('its child is gone', ~PsychLVGL('IsValid', kid));
    plv_assert('the style is gone', ~PsychLVGL('IsValid', st));
    plv_assert('the series is gone', ~PsychLVGL('IsValid', ser));

    scr = PsychLVGL('ScreenActive');
    s2 = PsychLVGL('ScreenCreate');
    PsychLVGL('ScreenLoad', s2);
    PsychLVGL('ObjCreate', scr);
    PsychLVGL('Update', 300, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 120, 80);
    PsychLVGL('Update', 301, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Shutdown');
    plv_assert('Shutdown after ScreenLoad of a created screen returns', true);
end
