function tf = IsWin(varargin)
% ISWIN  Test stub, not Psychtoolbox. True when plv_stub_input
%   'platform' is 'windows', so one machine can test every platform branch.
    tf = strcmp(plv_stub_input('get', 'platform'), 'windows');
end
