function PsychLVGLXMLDemo(seconds, screenshot)
% PSYCHLVGLXMLDEMO  A Gabor patch driven by a panel loaded from XML.
%
%   PsychLVGLXMLDemo              Runs until ESCAPE.
%   PsychLVGLXMLDemo(seconds)     Runs for that long.
%   PsychLVGLXMLDemo([], file)    Plays a short scripted sequence, saves the
%                                 window as a PNG to file and returns; see
%                                 tools/CaptureReadmeScreenshot.m.
%
%   The panel is tests/xml/demo/gabor_panel.xml, a screen as the LVGL editor
%   saves it, with the components and declarations next to it. The demo
%   builds nothing itself: PsychLVGLLoadXML creates every widget, and the
%   subject "contrast" ties the slider, the arc, the value tile and the
%   three buttons together. Each frame, PsychLVGLSubjects moves the events
%   into the subjects, and the demo draws the Gabor with the contrast, the
%   spatial frequency and the drift the subjects hold. The small image in
%   the panel is a Psychtoolbox texture drawn by LVGL with no copy.
%
%   Psychtoolbox with a working OpenGL context is required, and the source
%   tree: the XML and the window helper live under tests/.

    if nargin < 1 || isempty(seconds)
        seconds = Inf;
    end
    if nargin < 2
        screenshot = '';
    end

    root = fileparts(fileparts(mfilename('fullpath')));
    xml = fullfile(root, 'tests', 'xml', 'demo', 'gabor_panel.xml');
    if exist(xml, 'file') ~= 2
        error('psychlvgl:NotFound', ...
              'PsychLVGLXMLDemo needs the source tree: %s is missing', xml);
    end
    % Both path entries go on before the first call into the MEX; the
    % window helper is the one place that sets the test preferences.
    addpath(fullfile(root, 'tests', 'gl'));
    PsychLVGLSetup();

    PsychDefaultSetup(2);
    [win, winRect] = ptb_test_window([0 0 1280 720], 0.5);

    panelW = 440;
    panelH = 680;
    dst = [20, 20, 20 + panelW, 20 + panelH];
    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() plv_demo_close(ui)); %#ok<NASGU>

    [~, named] = PsychLVGLLoadXML(xml);
    PsychLVGL('AddToGroup', named.contrast_slider);
    PsychLVGL('AddToGroup', named.freq_dd);

    % A Psychtoolbox texture shown inside the panel: a color wheel.
    [x, y] = meshgrid(linspace(-1, 1, 64));
    hue = (atan2(y, x) + pi) / (2 * pi);
    wheel = cat(3, 0.5 + 0.5 * cos(2 * pi * hue), 0.5 + 0.5 * cos(2 * pi * (hue - 1/3)), ...
                0.5 + 0.5 * cos(2 * pi * (hue - 2/3)));
    wheel = wheel .* repmat(double(hypot(x, y) <= 1), [1 1 3]);
    wheelTex = Screen('MakeTexture', win, uint8(255 * wheel), [], 1);
    img = PsychLVGLImageFromTexture(win, wheelTex);
    PsychLVGL('ImageSetSrc', named.stim_image, img);

    freqs = [2 4 8];
    gaborRect = CenterRect([0 0 420 420], [dst(3) 0 winRect(3) winRect(4)]);
    % disableNorm = 1 and contrastPreMultiplicator = 0.5 make the contrast
    % argument the Michelson contrast around the 0.5 gray; see PsychLVGLDemo.
    gabortex = CreateProceduralGabor(win, 420, 420, 0, [0.5 0.5 0.5 0], 1, 0.5);

    scripted = ~isempty(screenshot);
    shown = '';
    trial = 0;
    running = true;
    checked = false;
    phase = 0;
    frame = 0;
    tStop = GetSecs() + seconds;
    while running
        frame = frame + 1;
        if scripted
            % A few seconds of made-up use, so the chart has a history and
            % the widgets show values other than their defaults.
            named.subjects = PsychLVGLSubjects('set', named.subjects, 'contrast', ...
                                               round(55 + 30 * sin(frame / 9)));
        end

        [ui, E] = PsychLVGLFrame(ui);
        named.subjects = PsychLVGLSubjects('update', named.subjects, E);
        contrast = PsychLVGLSubjects('get', named.subjects, 'contrast') / 100;
        freq = freqs(PsychLVGLSubjects('get', named.subjects, 'freq') + 1);
        drift = PsychLVGLSubjects('get', named.subjects, 'drift') ~= 0;
        status = sprintf('contrast %.2f, %d cyc/deg, trial %d', contrast, freq, trial + 1);
        if ~strcmp(status, shown)
            PsychLVGL('LabelSetText', named.status, status);
            shown = status;
        end
        % A made-up block of trials, one every 60 frames, so the bar and the
        % table have something to show; the last two trials are listed.
        PsychLVGL('BarSetValue', named.progress, round(100 * mod(frame, 60) / 60), false);
        if mod(frame, 60) == 0
            trial = trial + 1;
            row = 2 - mod(trial, 2);
            PsychLVGL('TableSetCellValue', named.trials, row, 0, sprintf('%d', trial));
            PsychLVGL('TableSetCellValue', named.trials, row, 1, sprintf('%.2f', contrast));
            PsychLVGL('TableSetCellValue', named.trials, row, 2, sprintf('%d cyc/deg', freq));
        end
        % A chart point costs a redraw of the plot, so one every few frames.
        if mod(frame, 3) == 0
            PsychLVGL('ChartSetNextValue', named.history, named.history_series, round(100 * contrast));
        end

        if drift
            phase = phase + 4;
        end
        Screen('DrawTexture', win, gabortex, [], gaborRect, 0, [], [], [1 1 1 0], [], ...
               kPsychDontDoRotation, [phase, freq / 100, 60, contrast, 1, 0, 0, 0]);

        if ~checked
            sd = gabor_std(win, gaborRect);
            if sd < 0.02 && contrast > 0.2
                error('psychlvgl:GaborFlat', ...
                      'the Gabor is flat: pixel standard deviation %.4f is below 0.02', sd);
            end
            checked = true;
        end

        % Frame 184 is a peak of the scripted sweep, after the chart has
        % filled: a high contrast Gabor and a full history.
        if scripted && frame == 184
            plv_save_screenshot(win, screenshot);
            running = false;
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
            % No keyboard on this machine.
        end
    end
end

function plv_save_screenshot(win, file)
% The whole back buffer before the flip; a sub-rectangle of a windowed
% window read back stale pixels here (SPEC D24).
    shot = Screen('GetImage', win, [], 'backBuffer');
    d = fileparts(file);
    if ~isempty(d) && exist(d, 'dir') ~= 7
        mkdir(d);
    end
    imwrite(shot, file);
    info = dir(file);
    fprintf('screenshot %s: %dx%d, %.0f KB\n', file, size(shot, 2), size(shot, 1), info.bytes / 1024);
end

function plv_demo_close(ui)
    PsychLVGLClose(ui);
    ptb_test_window_close();
end
