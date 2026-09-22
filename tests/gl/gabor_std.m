function [s, img] = gabor_std(win, rect)
% GABOR_STD  Pixel standard deviation of a region of the back buffer.
%
%   [s, img] = gabor_std(win, rect)
%
%   img comes back as double in 0 to 1. The back buffer is read before the
%   flip, because after a flip its contents are undefined.
%
%   A Gaussian envelope leaves most of a square patch flat gray, so the
%   standard deviation of a correct Gabor is small: about 0.07 for Michelson
%   contrast 0.6 with sigma 50 in a 256 pixel box. Compare against a flat
%   patch rather than against an absolute number.

    img = Screen('GetImage', win, rect, 'drawBuffer');
    img = double(img);
    if max(img(:)) > 1.5
        img = img / 255;   % uint8 read back
    end
    s = std(img(:));
end
