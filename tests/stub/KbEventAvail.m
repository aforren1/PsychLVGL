function n = KbEventAvail(deviceIndex)
% KBEVENTAVAIL  Test stub, not Psychtoolbox. The number of events that
%   plv_stub_input 'push' queued on deviceIndex; [] is the default keyboard.
    if nargin < 1; deviceIndex = []; end
    n = plv_stub_input('avail', deviceIndex);
end
