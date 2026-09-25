function [ui, E, events] = PsychLVGLFrame(ui)
% PSYCHLVGLFRAME  Runs one LVGL frame and draws the panel.
%
%   [ui, E] = PsychLVGLFrame(ui)
%   [ui, E, events] = PsychLVGLFrame(ui)
%
%   ui   The struct PsychLVGLOpen returned.
%   E    The event matrix, Nx5, oldest first. PsychLVGLEvents('decode', E)
%        turns it into a struct array. Its time column is the time of this
%        frame's Update, the same for every widget event of the frame.
%   events  The raw device events of this frame, an Nx1 struct array in
%        time order (0x1 when there is none) with the fields time, device,
%        kind, code, name, pressed and cooked. time is when Psychtoolbox
%        recorded the device event; use it for reaction times. ui.events
%        holds the same array. See help PsychLVGLInput for the fields.
%
%   One call does everything SPEC section 4.3 shows per frame: it polls the
%   mouse, the wheel and the keyboard in panel coordinates, on the devices
%   that opts.KeyboardIndex and opts.MouseIndex of PsychLVGLOpen name, wraps
%   PsychLVGL('Update') in Screen('BeginOpenGL') and Screen('EndOpenGL'),
%   draws the panel texture into the destination rectangle, and drains the
%   event queue.
%
%   The caller still owns Screen('Flip'), so the panel can be drawn together
%   with the stimulus in one frame.
%
%   Example:
%       while running
%           [ui, E] = PsychLVGLFrame(ui);
%           S = PsychLVGLEvents('decode', E);
%           for k = 1:numel(S)
%               if S(k).target == slider && strcmp(S(k).name, 'VALUE_CHANGED')
%                   contrast = S(k).param / 100;
%               end
%           end
%           Screen('DrawTexture', win, stimulus);
%           Screen('Flip', win);
%       end
%
%   See also PSYCHLVGLOPEN, PSYCHLVGLGL, PSYCHLVGLCLOSE, PSYCHLVGLEVENTS.

    if nargin < 1 || ~isstruct(ui) || ~isfield(ui, 'win')
        error('psychlvgl:Usage', ...
              'Usage: [ui, E] = PsychLVGLFrame(ui), with the struct PsychLVGLOpen returned');
    end

    tNow = plv_now();
    % ui.kq comes back because it keeps the part of a wheel click that is
    % not complete yet.
    [mouse, wheel, keys, ui.kq, events] = PsychLVGLInput('Poll', ui.kq, ui.win, ui.dst, ui.w, ui.h);
    ui.events = events;

    plv_wrap_update(ui.win, tNow, mouse, wheel, keys);

    % No source rectangle: a texture rendered through a framebuffer object
    % already matches the row order Psychtoolbox expects, which
    % tests/gl/test_gl_render checks.
    Screen('DrawTexture', ui.win, ui.tex, [], ui.dst);

    PsychLVGL('StatsAddFrame', tNow - ui.tLast);
    ui.tLast = tNow;

    if nargout > 1
        E = PsychLVGL('Poll');
    end
end

function plv_wrap_update(win, tNow, mouse, wheel, keys)
% onCleanup, not a plain call pair: a MEX error inside Update must still
% leave Psychtoolbox in 2D mode.
    Screen('BeginOpenGL', win);
    back2d = onCleanup(@() plv_end_gl(win)); %#ok<NASGU>
    PsychLVGL('Update', tNow, mouse, wheel, keys);
end

function plv_end_gl(win)
    try
        Screen('EndOpenGL', win);
    catch
        % The window is already gone; nothing left to switch back to.
    end
end

function t = plv_now()
    if exist('GetSecs', 'file') ~= 0
        t = GetSecs();
    else
        t = now() * 86400;
    end
end
