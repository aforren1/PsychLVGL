function c = psychlvgl_gabor_michelson(img, halfWidth)
% PSYCHLVGL_GABOR_MICHELSON  Michelson contrast of the middle of a Gabor patch.
%   A copy of tests/gl/gabor_michelson for the demos, in m/private so that
%   a release package runs them without a path change.
%
%   c = psychlvgl_gabor_michelson(img, halfWidth)
%
%   img is double in 0 to 1. Only the middle is used, where the Gaussian
%   envelope is close to 1, so the result is the carrier contrast rather than
%   an average over the skirts.

    if nargin < 2 || isempty(halfWidth)
        halfWidth = 30;
    end
    g = mean(double(img), 3);
    [h, w] = size(g);
    r = max(1, round(h / 2) - halfWidth):min(h, round(h / 2) + halfWidth);
    c = max(1, round(w / 2) - halfWidth):min(w, round(w / 2) + halfWidth);
    patch = g(r, c);
    hi = max(patch(:));
    lo = min(patch(:));
    if (hi + lo) <= 0
        c = 0;
        return;
    end
    c = (hi - lo) / (hi + lo);
end
