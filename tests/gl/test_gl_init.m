function test_gl_init()
% TEST_GL_INIT  Init returns a texture id and reports the NanoVG backend.
%   Needs Psychtoolbox and a GPU. run_tests skips this file when Screen is
%   not usable.

    if ~plv_gl_available(); plv_gl_skip('test_gl_init'); return; end

    % Before any window exists nothing has made a GL context current on this
    % thread, so this is where the check can be observed. Once Psychtoolbox
    % opens a window its own context stays current on the main thread even
    % outside BeginOpenGL, so the MEX cannot tell the two apart there.
    plv_throws('Init with no GL context raises NoGLContext', ...
               'psychlvgl:NoGLContext', @() PsychLVGL('Init', 200, 200));

    win = ptb_test_window();

    Screen('BeginOpenGL', win);
    glTex = PsychLVGL('Init', 200, 200);
    Screen('EndOpenGL', win);

    plv_assert('Init returns a nonzero texture id', glTex > 0);

    v = PsychLVGL('Version');
    plv_eq('Version reports the GL build', v.build, 'gl');
    plv_assert('Version names the NanoVG backend', ...
               any(strcmp(v.nanovgBackend, {'GL2', 'GL3', 'GLES2', 'GLES3'})));
    plv_assert('Version reports the GL version', ~isempty(v.glVersion));
    plv_assert('Version reports the renderer', ~isempty(v.glRenderer));

    Screen('BeginOpenGL', win);
    PsychLVGL('Shutdown');
    Screen('EndOpenGL', win);
end
