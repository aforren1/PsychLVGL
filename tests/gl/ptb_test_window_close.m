function ptb_test_window_close()
% PTB_TEST_WINDOW_CLOSE  Closes the window ptb_test_window cached.
    clear ptb_test_window
    try
        sca();
    catch
        % no window was open
    end
end
