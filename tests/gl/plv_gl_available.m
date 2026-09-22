function tf = plv_gl_available()
% PLV_GL_AVAILABLE  True when Psychtoolbox can open a window here.
    tf = false;
    if exist('Screen', 'file') ~= 3; return; end
    try
        Screen('Version');
        tf = true;
    catch
        tf = false;
    end
end
