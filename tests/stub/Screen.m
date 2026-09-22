function varargout = Screen(cmd, varargin)
% SCREEN  Test stub, not Psychtoolbox.
%
%   tests/test_helpers.m puts this directory at the front of the path so that
%   the PsychLVGL helper layer can be exercised with no window and no GPU. It
%   records every call and answers the few commands the helpers use.
%
%   Control commands, which the real Screen does not have:
%     Screen('stubReset')            clear the log, 3D on, draw mode 2D
%     log = Screen('stubLog')        cellstr of the commands seen, in order
%     Screen('stubSet3D', tf)        what Preference Enable3DGraphics returns
%     Screen('stubKillWindow')       later window calls raise an error
%     m = Screen('stubDrawMode')     0 for 2D, 1 for userspace OpenGL
%     n = Screen('stubBeginDepth')   how deep BeginOpenGL is nested
%     t = Screen('stubClosedTextures')  handles passed to Screen('Close')

    persistent log enable3d drawmode dead nexttex begindepth closedtex

    if isempty(enable3d);   enable3d = 1;   end
    if isempty(drawmode);   drawmode = 0;   end
    if isempty(dead);       dead = false;   end
    if isempty(nexttex);    nexttex = 100;  end
    if isempty(begindepth); begindepth = 0; end
    if isempty(log);        log = {};       end
    if isempty(closedtex);  closedtex = []; end

    switch cmd
        case 'stubReset'
            % Handle bookkeeping survives a reset on purpose: a texture
            % handed out before it must still look like a texture after it.
            log = {}; enable3d = 1; drawmode = 0; dead = false;
            begindepth = 0;
            return;
        case 'stubLog'
            varargout{1} = log;
            return;
        case 'stubSet3D'
            enable3d = varargin{1};
            return;
        case 'stubKillWindow'
            dead = true;
            return;
        case 'stubDrawMode'
            varargout{1} = drawmode;
            return;
        case 'stubBeginDepth'
            varargout{1} = begindepth;
            return;
        case 'stubClosedTextures'
            varargout{1} = closedtex;
            return;
    end

    log{end + 1} = cmd; %#ok<AGROW>

    switch cmd
        case 'Preference'
            name = varargin{1};
            if strcmp(name, 'Enable3DGraphics')
                varargout{1} = enable3d;
                if numel(varargin) > 1; enable3d = varargin{2}; end
            else
                varargout{1} = 0;
            end

        case 'BeginOpenGL'
            plv_check_window(dead);
            if drawmode ~= 0
                error('psychlvgl:stub', 'BeginOpenGL called while already in 3D mode');
            end
            drawmode = 1;
            begindepth = begindepth + 1;

        case 'EndOpenGL'
            plv_check_window(dead);
            if drawmode == 0
                error('psychlvgl:stub', 'EndOpenGL called while in 2D mode');
            end
            drawmode = 0;

        case 'GetOpenGLDrawMode'
            % Same shape as the real one: the target window first, the
            % userspace flag second.
            varargout{1} = 1;
            if nargout > 1; varargout{2} = drawmode; end

        case 'SetOpenGLTexture'
            plv_check_window(dead);
            nexttex = nexttex + 1;
            varargout{1} = nexttex;

        case 'WindowKind'
            % -1 for a texture, 1 for an onscreen window, 0 when the handle
            % is not in use. The stub hands out texture handles above 100.
            h = varargin{1};
            if dead || h <= 0 || any(closedtex == h)
                varargout{1} = 0;
            elseif h > 100 && h <= nexttex
                varargout{1} = -1;
            else
                varargout{1} = 1;
            end

        case 'Rect'
            plv_check_window(dead);
            varargout{1} = [0 0 640 480];

        case 'WindowSize'
            plv_check_window(dead);
            varargout{1} = 640;
            if nargout > 1; varargout{2} = 480; end

        case 'Close'
            plv_check_window(dead);
            h = varargin{1};
            if ~(h > 100 && h <= nexttex)
                error('psychlvgl:stub', 'Close on a handle that is not a texture');
            end
            closedtex(end + 1) = h; %#ok<AGROW>
            if nargout > 0; varargout{1} = 0; end

        case {'DrawTexture', 'Flip'}
            plv_check_window(dead);
            if nargout > 0; varargout{1} = 0; end

        case 'Version'
            varargout{1} = struct('version', 'stub');

        otherwise
            if nargout > 0; varargout{1} = 0; end
    end
end

function plv_check_window(dead)
    if dead
        error('psychlvgl:stub', 'the window is closed');
    end
end
