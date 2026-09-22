function test_keypad()
% TEST_KEYPAD  Key rows reach a focused text area as text.

    PsychLVGL('Init', 200, 200);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    ta = PsychLVGL('TextareaCreate', scr);
    PsychLVGL('TextareaSetOneLine', ta, true);
    PsychLVGL('ObjSetPos', ta, 5, 5);
    PsychLVGL('ObjSetSize', ta, 180, 40);
    PsychLVGL('TextareaSetText', ta, '');
    PsychLVGL('AddToGroup', ta);
    PsychLVGL('FocusObj', ta);

    t = 10;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));

    % CookedKey values: printable code points go in as text
    keys = [double('a') 1; double('a') 0; ...
            double('b') 1; double('b') 0; ...
            double('c') 1; double('c') 0];
    t = t + 0.1;
    PsychLVGL('Update', t, [0 0 0], 0, keys);

    plv_eq('typed text reaches the text area', PsychLVGL('TextareaGetText', ta), 'abc');

    % LV_KEY_BACKSPACE removes the last character
    t = t + 0.1;
    PsychLVGL('Update', t, [0 0 0], 0, [8 1; 8 0]);
    plv_eq('backspace deletes one character', PsychLVGL('TextareaGetText', ta), 'ab');

    % more rows than the ring holds must not corrupt anything
    many = repmat([double('x') 1; double('x') 0], 40, 1);
    t = t + 0.1;
    PsychLVGL('Update', t, [0 0 0], 0, many);
    txt = PsychLVGL('TextareaGetText', ta);
    plv_assert('a long key burst is accepted', ischar(txt) && numel(txt) >= 2);

    plv_throws('keys must be Nx2', 'psychlvgl:Usage', ...
               @() PsychLVGL('Update', t + 1, [0 0 0], 0, [1 2 3]));

    % the key map is engine side and works without Psychtoolbox
    row = PsychLVGLKeyMap(struct('CookedKey', 97, 'Pressed', 1));
    plv_eq('KeyMap passes a cooked key through', row, [97 1]);
    row = PsychLVGLKeyMap(struct('CookedKey', 0, 'Pressed', 1, 'KeyName', 'UpArrow'));
    plv_eq('KeyMap maps UpArrow to LV_KEY_UP', row, [17 1]);
    row = PsychLVGLKeyMap(struct('CookedKey', 0, 'Pressed', 1, 'KeyName', 'tab'), true);
    plv_eq('shift with tab gives LV_KEY_PREV', row, [11 1]);
    row = PsychLVGLKeyMap(struct('CookedKey', 0, 'Pressed', 1, 'KeyName', 'F13'));
    plv_assert('an unmapped key is dropped', isempty(row));
end
