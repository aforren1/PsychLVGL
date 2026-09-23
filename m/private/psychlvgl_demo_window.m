function [win, rect] = psychlvgl_demo_window(rect, background)
% PSYCHLVGL_DEMO_WINDOW  Opens, and then reuses, the windowed Psychtoolbox window
%   of PsychLVGLDemo and PsychLVGLXMLDemo. A copy of tests/gl/ptb_test_window
%   under a name that cannot shadow it, in m/private so that the demos run
%   from a release package without a path change.
%
%   [win, rect] = psychlvgl_demo_window()                 640x480 at the top left
%   [win, rect] = psychlvgl_demo_window(rect)             a different rectangle
%   [win, rect] = psychlvgl_demo_window(rect, background) a different clear colour
%
%   The window is cached and reused, whatever rect a later call asks for.
%   LVGL can only build its NanoVG renderer once per process and the renderer
%   caches an OpenGL framebuffer name, so every demo run in one session has
%   to use one OpenGL context. psychlvgl_demo_window_close closes it.
%
%   SkipSyncTests and VisualDebugLevel are set here so that repeated demo runs
%   skip the display sync calibration and the startup splash. Never use these
%   settings for a real experiment session.

    persistent cached_win cached_rect

    if ~isempty(cached_win)
        try
            Screen('WindowSize', cached_win);
            win = cached_win;
            rect = cached_rect;
            return;
        catch
            cached_win = [];
        end
    end

    if nargin < 1 || isempty(rect)
        rect = [0 0 640 480];
    end
    if nargin < 2 || isempty(background)
        background = 0;
    end

    AssertOpenGL();
    InitializeMatlabOpenGL(1);
    Screen('Preference', 'SkipSyncTests', 2);
    Screen('Preference', 'VisualDebugLevel', 0);

    screenid = max(Screen('Screens'));
    [win, rect] = PsychImaging('OpenWindow', screenid, background, rect);

    cached_win = win;
    cached_rect = rect;
end
