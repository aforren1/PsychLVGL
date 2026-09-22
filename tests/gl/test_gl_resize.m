function test_gl_resize()
% TEST_GL_RESIZE  Init at a new size gives a new texture and invalidates the
%   old handles (SPEC rule R5).
%
%   The second Init goes through PsychLVGLGL rather than a second
%   PsychLVGLOpen, because rule R5 is about Init alone and a second Open would
%   also build a second keyboard queue and a second Psychtoolbox texture.

    if ~plv_gl_available(); plv_gl_skip('test_gl_resize'); return; end

    win = ptb_test_window();

    ui = PsychLVGLOpen(win, 200, 120);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    old = PsychLVGL('ObjCreate', PsychLVGL('ScreenActive'));
    tex1 = ui.glTex; %#ok<NASGU>

    % The script owns the Psychtoolbox texture, so it releases the old wrapper
    % before the panel texture behind it goes.
    Screen('Close', ui.tex);

    tex2 = PsychLVGLGL(ui, 'Init', 240, 160);

    % Init hands back a texture the script has to wrap again. The integer is
    % not required to differ: OpenGL reuses a name it just freed.
    plv_assert('the new panel has a texture id', tex2 > 0);
    plv_assert('old handles are invalid', ~PsychLVGL('IsValid', old));
    plv_eq('the wrapper left 2D mode', plv_gl_drawmode(), 0);

    global GL %#ok<GVMIS>
    ui.glTex = tex2;
    ui.w = 240;
    ui.h = 160;
    ui.dst = [10 10 250 170];
    ui.tex = Screen('SetOpenGLTexture', win, [], tex2, GL.TEXTURE_2D, 240, 160, 32);

    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 255 0]);
    PsychLVGL('ObjSetStyleBgOpa', scr, 255);

    ui = PsychLVGLFrame(ui);
    img = double(Screen('GetImage', win, ui.dst, 'drawBuffer'));
    Screen('Flip', win);

    m = squeeze(mean(mean(img, 1), 2));
    plv_assert('the re-wrapped texture draws', m(2) > m(1) + 40);
end
