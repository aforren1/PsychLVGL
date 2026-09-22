function test_helpers()
% TEST_HELPERS  The four helper M-files, with a Psychtoolbox stub.
%
%   tests/stub holds a Screen that records its calls plus the handful of
%   keyboard and mouse functions the helpers reach. run_tests puts that
%   directory on the path once, before the first call into the MEX, and takes
%   it off again after the last test.
%
%   This file must not add or remove a path entry and must not call rehash.
%   Changing the load path while the MEX is loaded sends Octave 10 into
%   unbounded recursion in out_of_date_check, which ends as a stack overflow.
%   SPEC deviation D35 has the backtrace.
%
%   The point is the wrapping logic: every BeginOpenGL has a matching
%   EndOpenGL, an error inside the wrapped region still leaves 2D mode, the
%   missing 3D graphics case is reported, and PsychLVGLGL does not nest.

    plv_assert('the stub Screen is on the path', ...
               ~isempty(strfind(which('Screen'), 'stub'))); %#ok<STREMP>

    % --- the 3D graphics check ------------------------------------------
    Screen('stubReset');
    Screen('stubSet3D', 0);
    plv_throws('Open without 3D graphics raises No3D', 'psychlvgl:No3DGraphics', ...
               @() PsychLVGLOpen(1, 100, 80));
    plv_eq('the failed Open never entered 3D mode', Screen('stubDrawMode'), 0);

    % --- Open ------------------------------------------------------------
    Screen('stubReset');
    ui = PsychLVGLOpen(1, 120, 90);

    plv_assert('Open returns a struct', isstruct(ui));
    plv_eq('Open keeps the window', ui.win, 1);
    plv_eq('Open keeps the panel size', [ui.w ui.h], [120 90]);
    plv_eq('the default rectangle is the top left corner', ui.dst, [0 0 120 90]);
    plv_assert('Open wrapped the texture', ui.tex > 0);
    plv_assert('Open reports itself open', ui.opened);
    plv_eq('Open left 2D mode', Screen('stubDrawMode'), 0);
    plv_eq('Open wrapped Init in one pair', Screen('stubBeginDepth'), 1);

    log = Screen('stubLog');
    plv_eq('Open asked about 3D graphics first', log{1}, 'Preference');
    plv_assert('Open called BeginOpenGL', any(strcmp(log, 'BeginOpenGL')));
    plv_assert('Open called EndOpenGL', any(strcmp(log, 'EndOpenGL')));
    plv_assert('Open wrapped the GL texture', any(strcmp(log, 'SetOpenGLTexture')));

    % --- a destination rectangle of its own ------------------------------
    PsychLVGLClose(ui);
    Screen('stubReset');
    ui = PsychLVGLOpen(1, 120, 90, [10 20 250 200]);
    plv_eq('Open keeps the destination rectangle', ui.dst, [10 20 250 200]);
    plv_throws('a malformed rectangle is rejected', 'psychlvgl:Usage', ...
               @() PsychLVGLOpen(1, 120, 90, [10 20 250]));

    % --- Frame -----------------------------------------------------------
    Screen('stubReset');
    scr = PsychLVGL('ScreenActive');
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, 'frame');

    [ui, E] = PsychLVGLFrame(ui);
    plv_assert('Frame returns the struct back', isstruct(ui));
    plv_assert('Frame returns an Nx5 event matrix', size(E, 2) == 5);
    plv_eq('Frame left 2D mode', Screen('stubDrawMode'), 0);
    plv_eq('Frame wrapped Update in one pair', Screen('stubBeginDepth'), 1);

    log = Screen('stubLog');
    plv_assert('Frame drew the panel', any(strcmp(log, 'DrawTexture')));
    plv_assert('Frame did not flip', ~any(strcmp(log, 'Flip')));
    plv_eq('BeginOpenGL and EndOpenGL are balanced', ...
           sum(strcmp(log, 'BeginOpenGL')), sum(strcmp(log, 'EndOpenGL')));

    s = PsychLVGL('Stats');
    plv_assert('Frame counted a frame time', s.frameCount >= 1);

    [ui, E2] = PsychLVGLFrame(ui); %#ok<ASGLU>
    plv_eq('a second Frame stays balanced', Screen('stubDrawMode'), 0);

    plv_throws('Frame rejects anything but the struct', 'psychlvgl:Usage', ...
               @() PsychLVGLFrame('not a struct'));

    % --- PsychLVGLGL ------------------------------------------------------
    Screen('stubReset');
    dirty = PsychLVGLGL(ui, 'Update', 2000, [0 0 0], 0, zeros(0, 2));
    plv_assert('GL returns the subcommand result', dirty == 0 || dirty == 1);
    plv_eq('GL left 2D mode', Screen('stubDrawMode'), 0);
    plv_eq('GL used one pair', Screen('stubBeginDepth'), 1);

    % Already inside a userspace region: the call must not nest a second pair.
    Screen('stubReset');
    Screen('BeginOpenGL', ui.win);
    PsychLVGLGL(ui, 'Update', 2001, [0 0 0], 0, zeros(0, 2));
    plv_eq('GL did not nest BeginOpenGL', Screen('stubBeginDepth'), 1);
    plv_eq('GL left the caller in 3D mode', Screen('stubDrawMode'), 1);
    Screen('EndOpenGL', ui.win);

    plv_throws('GL rejects anything but the struct', 'psychlvgl:Usage', ...
               @() PsychLVGLGL('not a struct', 'Version'));

    % --- an error inside the wrapped region -------------------------------
    Screen('stubReset');
    plv_throws('an error inside the wrap reaches the caller', ...
               'psychlvgl:InvalidHandle', ...
               @() PsychLVGLGL(ui, 'ObjGetWidth', 0));
    plv_eq('the failed call still left 2D mode', Screen('stubDrawMode'), 0);

    % --- Close ------------------------------------------------------------
    Screen('stubReset');
    PsychLVGLClose(ui);
    plv_eq('Close left 2D mode', Screen('stubDrawMode'), 0);
    log = Screen('stubLog');
    plv_assert('Close freed the texture', any(strcmp(log, 'Close')));
    plv_assert('Close shut the MEX down', ~plv_mex_is_up());

    PsychLVGLClose(ui);
    plv_assert('Close is safe twice', true);

    % --- Close after the window is gone -----------------------------------
    Screen('stubReset');
    ui = PsychLVGLOpen(1, 64, 48);
    Screen('stubKillWindow');
    PsychLVGLClose(ui);
    plv_assert('Close survives a closed window', ~plv_mex_is_up());
end

function tf = plv_mex_is_up()
% PsychLVGL('Poll') needs Init, so it is a cheap way to ask.
    try
        PsychLVGL('Poll');
        tf = true;
    catch
        tf = false;
    end
end
