function file = CaptureReadmeScreenshot(file)
% CAPTUREREADMESCREENSHOT  Regenerates docs/images/psychlvgl-xml-demo.png.
%   CaptureReadmeScreenshot() runs PsychLVGLXMLDemo in its scripted mode in a
%   1280x720 window: the panel from tests/xml/demo/gabor_panel.xml over a
%   drifting Gabor, with the contrast swept for a few seconds so the chart,
%   the arc and the tiles show values. It saves the last frame with
%   Screen('GetImage') and closes the window.
%
%   CaptureReadmeScreenshot(file) writes somewhere else.
%
%   Run it in a fresh MATLAB session with the GPU build (build, then
%   PsychLVGLSetup). The window helper sets SkipSyncTests and
%   VisualDebugLevel, as for every test window. The README image must stay
%   below about 400 KB; a 1280x720 PNG of the panel and the Gabor measured
%   well below that here.

    root = fileparts(fileparts(mfilename('fullpath')));
    if nargin < 1 || isempty(file)
        file = fullfile(root, 'docs', 'images', 'psychlvgl-xml-demo.png');
    end
    addpath(fullfile(root, 'm'));
    PsychLVGLXMLDemo([], file);
end
