function PsychLVGLDemo()
% PSYCHLVGLDEMO  A Gabor patch driven by an LVGL control panel.
%
%   PsychLVGLDemo
%
%   The panel holds a contrast slider, a spatial frequency dropdown, a subject
%   id text area and a status label. Click the slider or turn the wheel; press
%   ESCAPE to finish.
%
%   Psychtoolbox with a working OpenGL context is required.

    root = PsychLVGLSetup();
    % The demo opens its window through the same helper as the GL tests, which
    % is the one place that sets SkipSyncTests and VisualDebugLevel. Those two
    % preferences suit a demo, never a real session.
    addpath(fullfile(root, 'tests', 'gl'));

    panelW = 380;
    panelH = 420;

    [win, winRect] = ptb_test_window([0 0 900 700], 0.5);
    cleanup = onCleanup(@() ptb_test_window_close()); %#ok<NASGU>

    dst = [20, 20, 20 + panelW, 20 + panelH];
    panel = PsychLVGLFrame('Open', win, dst, panelW, panelH);
    kq = PsychLVGLInput('Start', win);

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
    gabortex = CreateProceduralGabor(win, 300, 300, 0, [0.5 0.5 0.5 0]);

    running = true;
    phase = 0;
    while running
        [E, panel] = PsychLVGLFrame('Update', panel, kq);

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
        Screen('DrawTexture', win, gabortex, [], gaborRect, 0, [], [], [], [], ...
               kPsychDontDoRotation, [phase, freq / 100, 40, contrast, 1, 0, 0, 0]);
        Screen('Flip', win);

        [down, ~, keyCode] = KbCheck(-1);
        if down && keyCode(KbName('ESCAPE'))
            running = false;
        end
    end

    PsychLVGLInput('Stop', kq);
    PsychLVGLFrame('Close', panel);
end
