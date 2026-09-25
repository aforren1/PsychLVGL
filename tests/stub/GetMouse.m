function [x, y, buttons] = GetMouse(varargin)
% GETMOUSE  Test stub, not Psychtoolbox. A still mouse at the origin.
%   PsychLVGLInput converts this to panel coordinates, so the value only has
%   to be a plausible window coordinate. The call and its window and device
%   arguments go to the plv_stub_input log.
    [x, y, buttons] = plv_stub_input('call', 'GetMouse', varargin);
end
