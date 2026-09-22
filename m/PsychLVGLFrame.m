function varargout = PsychLVGLFrame(cmd, varargin)
% PSYCHLVGLFRAME  One call per frame instead of the six in SPEC section 4.3.
%
%   panel = PsychLVGLFrame('Open', win, dst, panelW, panelH [, opts])
%       Wraps InitializeMatlabOpenGL, PsychLVGL('Init') inside
%       Screen('BeginOpenGL'), and Screen('SetOpenGLTexture'). Returns the
%       struct the caller keeps.
%
%   [E, panel] = PsychLVGLFrame('Update', panel, kq)
%       Input, BeginOpenGL, PsychLVGL('Update'), EndOpenGL, DrawTexture, and
%       the event matrix. The caller still owns Screen('Flip').
%
%   PsychLVGLFrame('Close', panel)
%
%   The panel struct holds win, tex, dst, w, h and the time of the previous
%   frame, which feeds PsychLVGL('StatsAddFrame').

    switch lower(cmd)
        case 'open'
            varargout{1} = do_open(varargin{:});
        case 'update'
            [E, p] = do_update(varargin{:});
            varargout{1} = E;
            if nargout > 1; varargout{2} = p; end
        case 'close'
            do_close(varargin{:});
        otherwise
            error('psychlvgl:Usage', 'unknown PsychLVGLFrame command "%s"', cmd);
    end
end

function panel = do_open(win, dst, panelW, panelH, opts)
    if nargin < 5; opts = struct(); end
    require_ptb();

    InitializeMatlabOpenGL(1);
    Screen('BeginOpenGL', win);
    glTex = PsychLVGL('Init', panelW, panelH, opts);
    Screen('EndOpenGL', win);

    global GL %#ok<GVMIS>
    tex = Screen('SetOpenGLTexture', win, [], glTex, GL.TEXTURE_2D, panelW, panelH);

    panel = struct('win', win, 'tex', tex, 'glTex', glTex, 'dst', dst, ...
                   'w', panelW, 'h', panelH, 'tLast', GetSecs());
end

function [E, panel] = do_update(panel, kq)
    require_ptb();
    tNow = GetSecs();

    [mouse, wheel, keys] = PsychLVGLInput('Poll', kq, panel.win, panel.dst, ...
                                          panel.w, panel.h);

    Screen('BeginOpenGL', panel.win);
    PsychLVGL('Update', tNow, mouse, wheel, keys);
    Screen('EndOpenGL', panel.win);

    % No source rectangle: a texture rendered through a framebuffer object
    % already matches the row order Psychtoolbox expects, which
    % tests/gl/test_gl_render checks.
    Screen('DrawTexture', panel.win, panel.tex, [], panel.dst);

    PsychLVGL('StatsAddFrame', tNow - panel.tLast);
    panel.tLast = tNow;
    E = PsychLVGL('Poll');
end

function do_close(panel)
    Screen('BeginOpenGL', panel.win);
    PsychLVGL('Shutdown');
    Screen('EndOpenGL', panel.win);
end

function require_ptb()
    if exist('Screen', 'file') == 0
        error('psychlvgl:NoPTB', ...
              'PsychLVGLFrame needs Psychtoolbox; it is not on the path.');
    end
end
