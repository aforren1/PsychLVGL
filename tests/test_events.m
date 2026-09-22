function test_events()
% TEST_EVENTS  Pointer events, the event mask, and ring overflow.

    PsychLVGL('Init', 200, 200);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    btn = PsychLVGL('ButtonCreate', scr);
    PsychLVGL('ObjSetPos', btn, 10, 10);
    PsychLVGL('ObjSetSize', btn, 100, 40);

    t = 100;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));   % lay the tree out
    PsychLVGL('Poll');

    t = t + 0.1;
    PsychLVGL('Update', t, [50 30 1], 0, zeros(0, 2)); % press inside the button
    t = t + 0.1;
    PsychLVGL('Update', t, [50 30 0], 0, zeros(0, 2)); % release at the same spot

    E = PsychLVGL('Poll');
    plv_assert('Poll returns an Nx5 matrix', size(E, 2) == 5 && size(E, 1) > 0);

    S = PsychLVGLEvents('decode', E);
    names = {S.name};
    plv_assert('PRESSED was queued', any(strcmp(names, 'PRESSED')));
    plv_assert('RELEASED was queued', any(strcmp(names, 'RELEASED')));
    plv_assert('CLICKED was queued', any(strcmp(names, 'CLICKED')));
    plv_assert('the target is the button', all([S.target] == btn));
    plv_assert('the time is the Update time', all([S.time] >= 100));

    R = PsychLVGLEvents('filter', E, btn, 'CLICKED');
    plv_eq('filter keeps one row', size(R, 1), 1);

    plv_eq('Poll empties the ring', size(PsychLVGL('Poll'), 1), 0);

    % LONG_PRESSED is not in the default mask
    PsychLVGL('RemoveEvent', btn, 'CLICKED');
    t = t + 0.1; PsychLVGL('Update', t, [50 30 1], 0, zeros(0, 2));
    t = t + 0.1; PsychLVGL('Update', t, [50 30 0], 0, zeros(0, 2));
    E = PsychLVGL('Poll');
    clicked = PsychLVGL('Enum', 'LV_EVENT_CLICKED');
    plv_assert('RemoveEvent drops the code', ~any(E(:, 2) == clicked));

    PsychLVGL('AddEvent', btn, 'CLICKED');
    t = t + 0.1; PsychLVGL('Update', t, [50 30 1], 0, zeros(0, 2));
    t = t + 0.1; PsychLVGL('Update', t, [50 30 0], 0, zeros(0, 2));
    E = PsychLVGL('Poll');
    plv_assert('AddEvent puts the code back', any(E(:, 2) == clicked));

    plv_throws('AddEvent rejects an unknown name', 'psychlvgl:Enum', ...
               @() PsychLVGL('AddEvent', btn, 'NOT_AN_EVENT'));

    % VALUE_CHANGED carries the widget value
    sl = PsychLVGL('SliderCreate', scr);
    PsychLVGL('SliderSetRange', sl, 0, 100);
    PsychLVGL('SliderSetValue', sl, 42, 0);
    PsychLVGL('AddToGroup', sl);
    PsychLVGL('FocusObj', sl);
    t = t + 0.1; PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Poll');
    % LV_KEY_RIGHT on a focused slider raises its value
    t = t + 0.1; PsychLVGL('Update', t, [0 0 0], 0, [19 1; 19 0]);
    E = PsychLVGL('Poll');
    vc = PsychLVGL('Enum', 'LV_EVENT_VALUE_CHANGED');
    rows = E(E(:, 2) == vc & E(:, 1) == sl, :);
    plv_assert('a key changed the slider', ~isempty(rows));
    if ~isempty(rows)
        plv_eq('VALUE_CHANGED carries the slider value', ...
               rows(end, 4), PsychLVGL('SliderGetValue', sl));
    end

    % overflow drops the oldest record and counts it
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 200, 200, struct('QueueCapacity', 16));
    scr = PsychLVGL('ScreenActive');
    btn = PsychLVGL('ButtonCreate', scr);
    PsychLVGL('ObjSetPos', btn, 10, 10);
    PsychLVGL('ObjSetSize', btn, 100, 40);
    t = 200;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Poll');
    for k = 1:20
        t = t + 0.05; PsychLVGL('Update', t, [50 30 1], 0, zeros(0, 2));
        t = t + 0.05; PsychLVGL('Update', t, [50 30 0], 0, zeros(0, 2));
    end
    E = PsychLVGL('Poll');
    s = PsychLVGL('Stats');
    plv_assert('the ring never grows past its capacity', size(E, 1) <= 16);
    plv_assert('overflow is counted', s.eventsDropped > 0);
    plv_assert('the high water mark is recorded', s.queueHighWater > 0);
end
