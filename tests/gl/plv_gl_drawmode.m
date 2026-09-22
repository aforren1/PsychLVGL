function mode = plv_gl_drawmode()
% PLV_GL_DRAWMODE  0 when Psychtoolbox draws in 2D, greater than 0 in the
%   userspace OpenGL context.
%
%   The first output of Screen('GetOpenGLDrawMode') is the target window, not
%   the mode, which is easy to get wrong.

    [targetWin, isUserspace] = Screen('GetOpenGLDrawMode'); %#ok<ASGLU>
    mode = isUserspace;
end
