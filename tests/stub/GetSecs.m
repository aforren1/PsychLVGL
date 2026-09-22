function t = GetSecs()
% GETSECS  Test stub, not Psychtoolbox.
%   A counter that only moves forward, so the tick the MEX derives from it is
%   monotonic and the frame times are reproducible.
    persistent counter
    if isempty(counter); counter = 1000; end
    counter = counter + 0.016;
    t = counter;
end
