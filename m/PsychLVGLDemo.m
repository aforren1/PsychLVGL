function PsychLVGLDemo(seconds)
% PSYCHLVGLDEMO  A Gabor patch driven by an LVGL control panel.
%
%   PsychLVGLDemo             Runs until ESCAPE.
%   PsychLVGLDemo(seconds)    Runs for that long, which is what a test does.
%
%   The panel holds a contrast slider, a spatial frequency dropdown, a subject
%   id text area and a status label. Drag the slider or turn the wheel; press
%   ESCAPE to finish.
%
%   The whole frame loop is four calls: PsychLVGLOpen, PsychLVGLFrame,
%   Screen('Flip') and PsychLVGLClose. No Screen('BeginOpenGL') pair appears
%   in this file.
%
%   Psychtoolbox with a working OpenGL context is required.

    if nargin < 1 || isempty(seconds)
        seconds = Inf;
    end

    % Both path entries go on before the first call into the MEX. The demo
    % opens its window through the same helper as the GL tests, which is the
    % one place that sets SkipSyncTests and VisualDebugLevel. Those two
    % preferences suit a demo, never a real session.
    root = fileparts(fileparts(mfilename('fullpath')));
    addpath(fullfile(root, 'tests', 'gl'));
    PsychLVGLSetup();

    panelW = 380;
    panelH = 420;

    % Before the window opens: PsychDefaultSetup(2) gives every window that
    % PsychImaging opens afterwards the normalized 0 to 1 colour range, which
    % is what the 0.5 gray background and the Gabor colour offset assume. It
    % is also what every Psychtoolbox demo does. The GL tests keep the default
    % range, so this belongs here rather than in ptb_test_window.
    PsychDefaultSetup(2);

    [win, winRect] = ptb_test_window([0 0 900 700], 0.5);

    dst = [20, 20, 20 + panelW, 20 + panelH];
    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    % One cleanup, so the panel always closes before the window. Two separate
    % onCleanup objects run in an order the engine chooses.
    closer = onCleanup(@() plv_demo_close(ui)); %#ok<NASGU>

    % --- build the panel once ---
    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [24 26 30]);
    PsychLVGL('ObjSetStyleBgOpa', scr, 230);

    title = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', title, 'Gabor controls');
    PsychLVGL('ObjAlign', title, 'LV_ALIGN_TOP_MID', 0, 10);

    slider = PsychLVGL('SliderCreate', scr);
    PsychLVGL('ObjSetSize', slider, 300, 18);
    PsychLVGL('ObjAlign', slider, 'LV_ALIGN_TOP_MID', 0, 60);
    PsychLVGL('SliderSetRange', slider, 0, 100);
    PsychLVGL('SliderSetValue', slider, 60, 0);
    PsychLVGL('AddToGroup', slider);

    dd = PsychLVGL('DropdownCreate', scr);
    PsychLVGL('DropdownSetOptions', dd, sprintf('2 cyc/deg\n4 cyc/deg\n8 cyc/deg'));
    PsychLVGL('ObjSetWidth', dd, 200);
    PsychLVGL('ObjAlign', dd, 'LV_ALIGN_TOP_MID', 0, 110);
    PsychLVGL('AddToGroup', dd);

    ta = PsychLVGL('TextareaCreate', scr);
    PsychLVGL('TextareaSetOneLine', ta, true);
    PsychLVGL('TextareaSetPlaceholderText', ta, 'subject id');
    PsychLVGL('ObjSetWidth', ta, 200);
    PsychLVGL('ObjAlign', ta, 'LV_ALIGN_TOP_MID', 0, 180);
    PsychLVGL('AddToGroup', ta);

    status = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', status, 'ready');
    PsychLVGL('ObjAlign', status, 'LV_ALIGN_BOTTOM_MID', 0, -12);

    % --- stimulus ---
    contrast = 0.6;
    freqs = [2 4 8];
    freq = freqs(1);
    gaborRect = CenterRect([0 0 300 300], winRect);
    % disableNorm = 1 and contrastPreMultiplicator = 0.5 make the contrast
    % argument the Michelson contrast around the 0.5 gray, which is what the
    % slider produces. With the default normalization the shader would scale
    % contrast by 1/(sqrt(2*pi)*sc), about 1/100 at sc = 40, and the patch
    % would look like flat gray. See CreateProceduralGabor.m lines 54 to 70.
    gabortex = CreateProceduralGabor(win, 300, 300, 0, [0.5 0.5 0.5 0], 1, 0.5);

    running = true;
    checked = false;
    phase = 0;
    tStop = GetSecs() + seconds;
    while running
        [ui, E] = PsychLVGLFrame(ui);

        S = PsychLVGLEvents('decode', E);
        for k = 1:numel(S)
            if S(k).target == slider && strcmp(S(k).name, 'VALUE_CHANGED')
                contrast = S(k).param / 100;
                PsychLVGL('LabelSetText', status, sprintf('contrast %.2f', contrast));
            elseif S(k).target == dd && strcmp(S(k).name, 'VALUE_CHANGED')
                freq = freqs(min(numel(freqs), S(k).param + 1));
                PsychLVGL('LabelSetText', status, sprintf('%d cyc/deg', freq));
            end
        end

        phase = phase + 4;
        % modulateColor is [1 1 1 0], not empty: the Michelson relation above
        % only holds while the modulation colour is unit white.
        Screen('DrawTexture', win, gabortex, [], gaborRect, 0, [], [], [1 1 1 0], [], ...
               kPsychDontDoRotation, [phase, freq / 100, 40, contrast, 1, 0, 0, 0]);

        if ~checked
            % One automated look at the first frame, so a shader or colour
            % range regression cannot turn the patch into flat gray unnoticed.
            % A Gaussian envelope leaves most of the box flat, so the pixel
            % standard deviation of a correct patch is small: measured 0.0501
            % here at contrast 0.6, against 0.0021 for the broken version.
            [sd, img] = gabor_std(win, gaborRect);
            mc = gabor_michelson(img);
            fprintf('gabor check: pixel std %.4f, central Michelson %.3f\n', sd, mc);
            if sd < 0.02
                error('psychlvgl:GaborFlat', ...
                      ['the Gabor is flat: pixel standard deviation %.4f is below ' ...
                       '0.02. Check PsychDefaultSetup(2), disableNorm and ' ...
                       'modulateColor.'], sd);
            end
            checked = true;
        end

        Screen('Flip', win);

        if GetSecs() >= tStop
            running = false;
        end
        try
            [down, ~, keyCode] = KbCheck(-1);
            if down && keyCode(KbName('ESCAPE'))
                running = false;
            end
        catch
            % No keyboard on this machine. The seconds argument or a closed
            % window is then the only way out.
        end
    end
end

function plv_demo_close(ui)
    PsychLVGLClose(ui);
    ptb_test_window_close();
end
