function tf = IsOSX(varargin)
% ISOSX  Test stub, not Psychtoolbox. True when plv_stub_input
%   'platform' is 'mac', so one machine can test every platform branch.
    tf = strcmp(plv_stub_input('get', 'platform'), 'mac');
end
