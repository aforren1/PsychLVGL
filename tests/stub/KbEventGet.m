function [evt, nremaining] = KbEventGet(deviceIndex, varargin)
% KBEVENTGET  Test stub, not Psychtoolbox. Pops the oldest event that
%   plv_stub_input 'push' queued on deviceIndex, or [] when there is none.
    if nargin < 1; deviceIndex = []; end
    plv_stub_input('call', 'KbEventGet', [{deviceIndex}, varargin]);
    evt = plv_stub_input('pop', deviceIndex);
    nremaining = plv_stub_input('avail', deviceIndex);
end
