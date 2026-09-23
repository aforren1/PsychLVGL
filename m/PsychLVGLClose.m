function PsychLVGLClose(ui)
% PSYCHLVGLCLOSE  Shuts the LVGL panel down and frees its texture.
%
%   PsychLVGLClose(ui)
%
%   ui   The struct PsychLVGLOpen returned.
%
%   The call wraps PsychLVGL('Shutdown') in Screen('BeginOpenGL') and
%   Screen('EndOpenGL'), closes the Psychtoolbox texture that wrapped the
%   OpenGL texture, and stops the keyboard queue. Shutdown deletes every
%   widget and then every style, image and font handle, so no handle from
%   this session stays valid. Psychtoolbox textures that ImageFromTexture
%   wrapped stay open; close them yourself.
%
%   It is safe to call twice, and safe after the window is already closed.
%   PsychLVGL('Shutdown') runs in every case, because that is what unlocks
%   the MEX and lets `clear mex` work.
%
%   See also PSYCHLVGLOPEN, PSYCHLVGLFRAME, PSYCHLVGLGL.

    if nargin < 1 || ~isstruct(ui)
        % Nothing to close, but still release the MEX if it is up.
        plv_shutdown_bare();
        return;
    end

    win = [];
    if isfield(ui, 'win'); win = ui.win; end

    alive = plv_window_alive(win);

    if alive
        ok = true;
        try
            Screen('BeginOpenGL', win);
        catch
            ok = false;
        end
        if ok
            back2d = onCleanup(@() plv_end_gl(win)); %#ok<NASGU>
            plv_shutdown_bare();
            clear back2d;
        else
            plv_shutdown_bare();
        end
    else
        % No context to make current. PsychLVGL('Shutdown') says so and
        % leaves the OpenGL objects to whoever owns the dead context.
        plv_shutdown_bare();
    end

    % Only close a handle that is still a texture. A stale handle makes
    % Screen('Close') raise a usage error, and Psychtoolbox tears the window
    % down when that happens, which is worse than leaking one texture.
    if alive && isfield(ui, 'tex') && ~isempty(ui.tex) && plv_is_texture(ui.tex)
        try
            Screen('Close', ui.tex);
        catch
            % The texture went with the window.
        end
    end

    if isfield(ui, 'kq')
        try
            PsychLVGLInput('Stop', ui.kq);
        catch
            % The queue was already stopped.
        end
    end
end

function plv_shutdown_bare()
    try
        PsychLVGL('Shutdown');
    catch
        % Already down, or the MEX is not on the path.
    end
end

function plv_end_gl(win)
    try
        Screen('EndOpenGL', win);
    catch
        % The window is already gone; nothing left to switch back to.
    end
end

function tf = plv_is_texture(tex)
% Screen('WindowKind') answers 0 for a handle that is not in use, 1 for an
% onscreen window and -1 for a texture or an offscreen window.
    tf = false;
    try
        tf = Screen('WindowKind', tex) == -1;
    catch
        tf = false;
    end
end

function tf = plv_window_alive(win)
% Screen('WindowKind') answers 1 for an open onscreen window and 0 for a
% handle that is not in use, and unlike Screen('Rect') it does not print a
% usage error for a window that is already closed.
    tf = false;
    if isempty(win) || exist('Screen', 'file') == 0
        return;
    end
    try
        tf = Screen('WindowKind', win) == 1;
    catch
        tf = false;
    end
end
