function psychlvgl_demo_window_close()
% PSYCHLVGL_DEMO_WINDOW_CLOSE  Closes the window psychlvgl_demo_window cached.
    clear psychlvgl_demo_window
    try
        sca();
    catch
        % no window was open
    end
end
