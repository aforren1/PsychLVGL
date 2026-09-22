function test_gl_demo_gabor()
% TEST_GL_DEMO_GABOR  The procedural Gabor the demo draws is visible.
%
%   PsychLVGLDemo once drew a flat gray square, because CreateProceduralGabor
%   normalizes the contrast by 1/(sqrt(2*pi)*sc) unless disableNorm is set,
%   and because the window was not in the normalized colour range. This test
%   pins the three settings that fix it: Screen('ColorRange', win, 1),
%   disableNorm = 1 with contrastPreMultiplicator = 0.5, and a unit
%   modulateColor.
%
%   Measured here at 300 px, sigma 40: pixel standard deviation 0.0501 and
%   central Michelson contrast 0.570 for a nominal contrast of 0.6.

    if ~plv_gl_available(); plv_gl_skip('test_gl_demo_gabor'); return; end

    win = ptb_test_window();
    Screen('ColorRange', win, 1);
    restoreRange = onCleanup(@() plv_restore_range(win)); %#ok<NASGU>

    rect = CenterRect([0 0 300 300], Screen('Rect', win));
    tex = CreateProceduralGabor(win, 300, 300, 0, [0.5 0.5 0.5 0], 1, 0.5);

    flat = draw_and_measure(win, tex, rect, 0);
    plv_assert('contrast 0 is flat', flat < 0.01);

    [sd, img] = draw_and_measure(win, tex, rect, 0.6);
    plv_assert('contrast 0.6 modulates the patch', sd > 0.02);
    plv_assert('contrast 0.6 is far above the flat patch', sd > 10 * max(flat, 1e-4));

    mc = gabor_michelson(img);
    plv_assert('the central Michelson contrast is the contrast asked for', ...
               abs(mc - 0.6) < 0.05);

    g = mean(img, 3);
    plv_assert('the patch swings below the gray', min(g(:)) < 0.45);
    plv_assert('the patch swings above the gray', max(g(:)) > 0.55);

    half = draw_and_measure(win, tex, rect, 0.3);
    plv_assert('halving the contrast halves the modulation', ...
               abs(half - sd / 2) < 0.2 * sd);

    Screen('Close', tex);
end

function [sd, img] = draw_and_measure(win, tex, rect, contrast)
    Screen('FillRect', win, 0.5);
    Screen('DrawTexture', win, tex, [], rect, 0, [], [], [1 1 1 0], [], ...
           kPsychDontDoRotation, [0, 0.02, 40, contrast, 1, 0, 0, 0]);
    [sd, img] = gabor_std(win, rect);
    Screen('Flip', win);
end

function plv_restore_range(win)
    try
        Screen('ColorRange', win, 255);
    catch
        % the window is gone
    end
end
