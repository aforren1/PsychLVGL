function ui = PsychLVGLOpen(win, w, h, dst, opts)
% PSYCHLVGLOPEN  Creates an LVGL panel for a Psychtoolbox window.
%
%   ui = PsychLVGLOpen(win, w, h)
%   ui = PsychLVGLOpen(win, w, h, dst)
%   ui = PsychLVGLOpen(win, w, h, dst, opts)
%
%   win    An open Psychtoolbox onscreen window.
%   w, h   Panel size in pixels. The panel is fixed at this size.
%   dst    Destination rectangle in the window, [x1 y1 x2 y2]. The default
%          puts the panel at the top left corner, [0 0 w h].
%   opts   Option struct for PsychLVGL('Init'), see help PsychLVGL. Two
%          more fields select the input devices; Init ignores them:
%            KeyboardIndex  keyboard device indices, as GetKeyboardIndices
%                           returns them. [] keeps the Psychtoolbox default.
%            MouseIndex     mouse device indices, as GetMouseIndices
%                           returns them. [] keeps the Psychtoolbox default.
%                           The pointer follows the first entry.
%          On a computer with more than one keyboard or mouse, set both.
%          A device can appear only once in the two lists together.
%          PsychLVGLInput('Devices') lists the indices.
%
%   The returned struct holds win, w, h, dst, tex, glTex, kq, KeyboardIndex,
%   MouseIndex, events (the raw device events of the last PsychLVGLFrame) and
%   opened. Keep it and give it to PsychLVGLFrame,
%   PsychLVGLGL and PsychLVGLClose.
%
%   This function does the work SPEC section 4.3 shows by hand: it wraps
%   PsychLVGL('Init') in Screen('BeginOpenGL') and Screen('EndOpenGL'), wraps
%   the OpenGL texture as a Psychtoolbox texture, and starts the keyboard
%   queue. A script that uses the four PsychLVGL helpers never writes a
%   BeginOpenGL and EndOpenGL pair itself.
%
%   Call PsychLVGLSetup first, and call InitializeMatlabOpenGL(1) before you
%   open the window. Psychtoolbox needs 3D graphics for the userspace OpenGL
%   context this binding renders in.
%
%   Example:
%       PsychLVGLSetup();
%       InitializeMatlabOpenGL(1);
%       win = PsychImaging('OpenWindow', 0, 0);
%       ui  = PsychLVGLOpen(win, 400, 300, [20 20 420 320]);
%       scr = PsychLVGL('ScreenActive');
%       btn = PsychLVGL('ButtonCreate', scr);
%       while true
%           [ui, E] = PsychLVGLFrame(ui);
%           Screen('Flip', win);
%       end
%       PsychLVGLClose(ui);
%
%   See also PSYCHLVGLFRAME, PSYCHLVGLGL, PSYCHLVGLCLOSE, PSYCHLVGLSETUP.

    if nargin < 3
        error('psychlvgl:Usage', 'Usage: ui = PsychLVGLOpen(win, w, h [, dst] [, opts])');
    end
    if nargin < 4 || isempty(dst)
        dst = [0 0 w h];
    end
    if nargin < 5 || isempty(opts)
        opts = struct();
    end
    if ~isstruct(opts)
        error('psychlvgl:Usage', 'opts must be a struct');
    end

    if exist('Screen', 'file') == 0
        error('psychlvgl:NoPTB', ...
              'PsychLVGLOpen needs Psychtoolbox; Screen is not on the path.');
    end
    if numel(dst) ~= 4
        error('psychlvgl:Usage', 'dst must be [x1 y1 x2 y2]');
    end
    % Checked here as well as in PsychLVGLInput('Start'), because Start runs
    % after Init, and a usage error there would leave the panel open.
    plv_input_indices(opts);

    % Screen('BeginOpenGL') fails unless the window was opened after
    % InitializeMatlabOpenGL, and the failure message does not say so.
    if Screen('Preference', 'Enable3DGraphics') == 0
        error('psychlvgl:No3DGraphics', ...
              ['Psychtoolbox 3D graphics are off, so Screen(''BeginOpenGL'') ' ...
               'cannot switch to the userspace OpenGL context.\n' ...
               'Call InitializeMatlabOpenGL(1) before you open the window.']);
    end

    glTex = plv_wrap_init(win, w, h, opts);

    % The depth is given rather than left out: without it Psychtoolbox reads
    % the format back from the texture, and the read fails when the texture
    % belongs to the userspace context rather than its own.
    tex = Screen('SetOpenGLTexture', win, [], glTex, plv_texture_2d(), w, h, 32);
    kq  = PsychLVGLInput('Start', win, opts);

    % The indices are copied to ui for the script to read; PsychLVGLFrame
    % uses the ones in kq, which Start checked.
    ui = struct('win', win, 'w', w, 'h', h, 'dst', dst(:)', ...
                'tex', tex, 'glTex', glTex, 'kq', kq, ...
                'KeyboardIndex', kq.KeyboardIndex, 'MouseIndex', kq.MouseIndex, ...
                'events', zeros(0, 6), 'opened', true, 'tLast', plv_now());
end

function glTex = plv_wrap_init(win, w, h, opts)
% onCleanup, not a plain call pair: an error inside PsychLVGL('Init') must
% still leave Psychtoolbox in 2D mode, or every later Screen call fails.
    Screen('BeginOpenGL', win);
    back2d = onCleanup(@() plv_end_gl(win)); %#ok<NASGU>
    glTex = PsychLVGL('Init', w, h, opts);
end

function plv_end_gl(win)
    try
        Screen('EndOpenGL', win);
    catch
        % The window is already gone; nothing left to switch back to.
    end
end

function id = plv_texture_2d()
% GL.TEXTURE_2D when InitializeMatlabOpenGL filled the global, else the
% constant itself, which never changes.
    global GL %#ok<GVMIS>
    if isstruct(GL) && isfield(GL, 'TEXTURE_2D')
        id = GL.TEXTURE_2D;
    else
        id = 3553;
    end
end

function t = plv_now()
    if exist('GetSecs', 'file') ~= 0
        t = GetSecs();
    else
        t = now() * 86400;
    end
end
