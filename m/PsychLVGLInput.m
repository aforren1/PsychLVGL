function varargout = PsychLVGLInput(cmd, varargin)
% PSYCHLVGLINPUT  Gathers mouse, wheel and keyboard input for PsychLVGL.
%
%   kq = PsychLVGLInput('Start', win)
%   [mouse, wheel, keys] = PsychLVGLInput('Poll', kq, win, dst, panelW, panelH)
%   PsychLVGLInput('Stop', kq)
%
%   'Start' creates and starts a keyboard queue. kq is a struct the caller
%   keeps; it holds the device index and the shift state.
%
%   'Poll' returns the three arguments PsychLVGL('Update') expects. Mouse
%   coordinates are panel pixels: the destination rectangle origin is
%   subtracted and the point is scaled when the destination differs in size
%   from the panel, so the script is free to draw the panel at any scale.
%
%   Psychtoolbox is required. Without it every call returns neutral values,
%   which is what lets the no-GL tests run.

    switch lower(cmd)
        case 'start'
            varargout{1} = do_start(varargin{:});
        case 'poll'
            [m, w, k] = do_poll(varargin{:});
            varargout{1} = m;
            if nargout > 1; varargout{2} = w; end
            if nargout > 2; varargout{3} = k; end
        case 'stop'
            do_stop(varargin{:});
        otherwise
            error('psychlvgl:Usage', 'unknown PsychLVGLInput command "%s"', cmd);
    end
end

function kq = do_start(win)
    if nargin < 1; win = []; end
    kq = struct('win', win, 'device', [], 'hasPTB', have_ptb(), 'shift', false);
    if ~kq.hasPTB
        warning('psychlvgl:NoPTB', ...
                'Psychtoolbox is not on the path; PsychLVGLInput returns neutral input.');
        return;
    end
    KbQueueCreate();
    KbQueueStart();
    GetMouseWheel();      % clear the click counter
end

function do_stop(kq)
    if nargin < 1 || ~isstruct(kq) || ~kq.hasPTB; return; end
    KbQueueStop();
    KbQueueRelease();
end

function [mouse, wheel, keys] = do_poll(kq, win, dst, panelW, panelH)
    mouse = [0 0 0];
    wheel = 0;
    keys = zeros(0, 2);

    if nargin < 5 || ~isstruct(kq) || ~kq.hasPTB
        return;
    end

    [x, y, buttons] = GetMouse(win);
    sx = panelW / max(1, dst(3) - dst(1));
    sy = panelH / max(1, dst(4) - dst(2));
    mouse = [(x - dst(1)) * sx, (y - dst(2)) * sy, double(any(buttons(1)))];

    try
        wheel = GetMouseWheel();
    catch
        wheel = 0;
    end
    if isempty(wheel); wheel = 0; end

    shift = kq.shift;
    while KbEventAvail()
        evt = KbEventGet();
        if isempty(evt); break; end
        row = PsychLVGLKeyMap(evt, shift);
        if ~isempty(row)
            keys(end + 1, :) = row; %#ok<AGROW>
        end
    end
end

function tf = have_ptb()
    tf = exist('Screen', 'file') ~= 0 && exist('KbQueueCreate', 'file') ~= 0;
end
