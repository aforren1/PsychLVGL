function varargout = PsychLVGLGL(ui, subcommand, varargin)
% PSYCHLVGLGL  Runs one PsychLVGL subcommand that needs an OpenGL context.
%
%   [...] = PsychLVGLGL(ui, subcommand, ...)
%
%   ui          The struct PsychLVGLOpen returned.
%   subcommand  Any subcommand marked GL in SPEC section 5, for example
%               'Update', or a numeric opcode.
%
%   The call wraps the subcommand in Screen('BeginOpenGL') and
%   Screen('EndOpenGL'). When the window is already in userspace OpenGL mode,
%   which the second output of Screen('GetOpenGLDrawMode') reports, the
%   subcommand runs directly, because nesting BeginOpenGL is an error.
%
%   Widget calls need no OpenGL context, so call PsychLVGL directly for them.
%   Only Init, Update and Shutdown touch OpenGL, and the other three helpers
%   already wrap those three. This function exists for the rest: a custom
%   frame loop, or a future GL subcommand.
%
%   Example:
%       dirty = PsychLVGLGL(ui, 'Update', GetSecs(), [0 0 0], 0, zeros(0, 2));
%
%   See also PSYCHLVGLOPEN, PSYCHLVGLFRAME, PSYCHLVGLCLOSE.

    if nargin < 2
        error('psychlvgl:Usage', 'Usage: PsychLVGLGL(ui, subcommand, ...)');
    end
    if ~isstruct(ui) || ~isfield(ui, 'win')
        error('psychlvgl:Usage', ...
              'the first argument must be the struct PsychLVGLOpen returned');
    end

    nout = max(nargout, 0);

    if plv_in_userspace()
        if nout == 0
            PsychLVGL(subcommand, varargin{:});
        else
            [varargout{1:nout}] = PsychLVGL(subcommand, varargin{:});
        end
        return;
    end

    Screen('BeginOpenGL', ui.win);
    back2d = onCleanup(@() plv_end_gl(ui.win)); %#ok<NASGU>
    if nout == 0
        PsychLVGL(subcommand, varargin{:});
    else
        [varargout{1:nout}] = PsychLVGL(subcommand, varargin{:});
    end
end

function tf = plv_in_userspace()
% The first output of Screen('GetOpenGLDrawMode') is the target window; the
% second is 0 for 2D drawing and greater than 0 while the userspace context
% is current.
    tf = false;
    try
        [targetWin, isUserspace] = Screen('GetOpenGLDrawMode'); %#ok<ASGLU>
        tf = isUserspace ~= 0;
    catch
        tf = false;
    end
end

function plv_end_gl(win)
    try
        Screen('EndOpenGL', win);
    catch
        % The window is already gone; nothing left to switch back to.
    end
end
