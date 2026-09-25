function tf = IsLinux(varargin)
% ISLINUX  Test stub, not Psychtoolbox. True when plv_stub_input
%   'platform' is 'linux', so one machine can test every platform branch.
    tf = strcmp(plv_stub_input('get', 'platform'), 'linux');
end
