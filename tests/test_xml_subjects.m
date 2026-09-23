function test_xml_subjects()
% TEST_XML_SUBJECTS  Subjects and bind_* attributes through PsychLVGLSubjects:
%   initial values reach the widgets, widget events update subjects, triggers
%   fire on clicks, and each change reaches every bound widget.

    fx = fullfile(fileparts(mfilename('fullpath')), 'xml');
    PsychLVGL('Init', 320, 320);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    plv_xml_collect('reset');
    [~, n] = PsychLVGLLoadXML(fullfile(fx, 'subjects.xml'), [], struct('Warn', @plv_xml_collect));
    plv_eq('subjects.xml loads without a warning', numel(plv_xml_collect('get')), 0);
    S = n.subjects;
    plv_eq('the subjects of globals.xml', S.names, {'level', 'flag', 'status'});
    plv_eq('an int subject', PsychLVGLSubjects('get', S, 'level'), 40);
    plv_eq('a string subject', PsychLVGLSubjects('get', S, 'status'), 'idle');

    % Loading pushed every subject once.
    plv_eq('bind_value on a slider', PsychLVGL('SliderGetValue', n.level_slider), 40);
    plv_eq('bind_value on an arc', PsychLVGL('ArcGetValue', n.level_arc), 40);
    plv_eq('bind_text with a format', PsychLVGL('LabelGetText', n.level_label), 'Level 40');
    plv_eq('bind_text of a string subject', PsychLVGL('LabelGetText', n.status_label), 'idle');
    plv_assert('bind_checked, unchecked at 0', ~PsychLVGL('ObjHasState', n.flag_box, 'LV_STATE_CHECKED'));
    plv_assert('bind_flag_if_eq hides the note at 0', PsychLVGL('ObjHasFlag', n.note, 'LV_OBJ_FLAG_HIDDEN'));
    plv_assert('bind_state_if_gt leaves the button enabled at 40', ...
               ~PsychLVGL('ObjHasState', n.danger, 'LV_STATE_DISABLED'));

    % An event row as Poll reports it: target, code, current target, param, time.
    VC = PsychLVGL('Enum', 'LV_EVENT_VALUE_CHANGED');
    CL = PsychLVGL('Enum', 'LV_EVENT_CLICKED');
    [S, changed] = PsychLVGLSubjects('update', S, [n.level_slider VC n.level_slider 70 0]);
    plv_eq('a slider event changes its subject', PsychLVGLSubjects('get', S, 'level'), 70);
    plv_eq('update names what changed', changed, {'level'});
    plv_eq('the change reaches the arc', PsychLVGL('ArcGetValue', n.level_arc), 70);
    plv_eq('and the label', PsychLVGL('LabelGetText', n.level_label), 'Level 70');

    [S, changed] = PsychLVGLSubjects('update', S, zeros(0, 5));
    plv_eq('no events, no change', changed, {});

    S = PsychLVGLSubjects('update', S, [n.inc CL n.inc 0 0]);
    plv_eq('subject_increment_event on click', PsychLVGLSubjects('get', S, 'level'), 80);
    plv_assert('80 is not above 80', ~PsychLVGL('ObjHasState', n.danger, 'LV_STATE_DISABLED'));
    S = PsychLVGLSubjects('update', S, [n.inc CL n.inc 0 0; n.inc CL n.inc 0 0; n.inc CL n.inc 0 0]);
    plv_eq('increment stops at max_value', PsychLVGLSubjects('get', S, 'level'), 100);
    plv_assert('bind_state_if_gt disables the button above 80', ...
               PsychLVGL('ObjHasState', n.danger, 'LV_STATE_DISABLED'));
    plv_eq('the slider follows', PsychLVGL('SliderGetValue', n.level_slider), 100);

    S = PsychLVGLSubjects('update', S, [n.go CL n.go 0 0]);
    plv_eq('subject_set_string_event', PsychLVGL('LabelGetText', n.status_label), 'running');

    S = PsychLVGLSubjects('update', S, [n.toggle CL n.toggle 0 0]);
    plv_eq('subject_toggle_event', PsychLVGLSubjects('get', S, 'flag'), 1);
    plv_assert('the note shows at 1', ~PsychLVGL('ObjHasFlag', n.note, 'LV_OBJ_FLAG_HIDDEN'));
    plv_assert('the checkbox follows', PsychLVGL('ObjHasState', n.flag_box, 'LV_STATE_CHECKED'));

    % bind_style adds the style at 1: the style sets bg_color, radius and
    % border width, and the checksum shows a change.
    layout();
    styled = PsychLVGL('FrameChecksum');
    S = PsychLVGLSubjects('set', S, 'flag', 0);
    layout();
    plv_assert('bind_style removes the style at 0', PsychLVGL('FrameChecksum') ~= styled);
    plv_assert('set pushes too', PsychLVGL('ObjHasFlag', n.note, 'LV_OBJ_FLAG_HIDDEN'));

    % A real click through Update and Poll on the toggle button.
    x = PsychLVGL('ObjGetX', n.toggle) + 10;
    y = PsychLVGL('ObjGetY', n.toggle) + 10;
    PsychLVGL('Poll');
    t = 500;
    PsychLVGL('Update', t, [x y 1], 0, zeros(0, 2));
    PsychLVGL('Update', t + 0.05, [x y 0], 0, zeros(0, 2));
    E = PsychLVGL('Poll');
    S = PsychLVGLSubjects('update', S, E);
    plv_eq('a real click toggles the subject', PsychLVGLSubjects('get', S, 'flag'), 1);

    % A real checkbox click changes the subject back through bind_checked.
    x = PsychLVGL('ObjGetX', n.flag_box) + 8;
    y = PsychLVGL('ObjGetY', n.flag_box) + 8;
    PsychLVGL('Update', t + 0.1, [x y 1], 0, zeros(0, 2));
    PsychLVGL('Update', t + 0.15, [x y 0], 0, zeros(0, 2));
    S = PsychLVGLSubjects('update', S, PsychLVGL('Poll'));
    plv_eq('a checkbox click writes its checked state to the subject', ...
           PsychLVGLSubjects('get', S, 'flag'), 0);
    plv_assert('and the note hides again', PsychLVGL('ObjHasFlag', n.note, 'LV_OBJ_FLAG_HIDDEN'));

    % Values outside the range are clamped; a deleted widget drops its binding.
    S = PsychLVGLSubjects('set', S, 'level', 500);
    plv_eq('an int subject is clamped to max_value', PsychLVGLSubjects('get', S, 'level'), 100);
    nb = numel(S.binds);
    PsychLVGL('ObjDelete', n.level_arc);
    S = PsychLVGLSubjects('set', S, 'level', 10);
    plv_eq('the binding of a deleted widget is dropped', numel(S.binds), nb - 1);
    plv_eq('the others still follow', PsychLVGL('SliderGetValue', n.level_slider), 10);

    % The helper on its own, without XML.
    T = PsychLVGLSubjects('create');
    T = PsychLVGLSubjects('add', T, 'x', 'float', 0.5, 0, 1);
    lbl = PsychLVGL('LabelCreate', PsychLVGL('ScreenActive'));
    T = PsychLVGLSubjects('bind', T, 'text', lbl, 'x', 'x = %.2f');
    T = PsychLVGLSubjects('apply', T);
    plv_eq('a float subject with a format', PsychLVGL('LabelGetText', lbl), 'x = 0.50');
    plv_throws('an unknown subject', 'psychlvgl:Usage', @() PsychLVGLSubjects('get', T, 'y'));
    plv_throws('an unknown verb', 'psychlvgl:Usage', @() PsychLVGLSubjects('frob', T));
    plv_throws('a second subject of one name', 'psychlvgl:Usage', ...
               @() PsychLVGLSubjects('add', T, 'x', 'int', 1));
end

function layout()
    persistent t
    if isempty(t); t = 300; end
    t = t + 0.05;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
end
