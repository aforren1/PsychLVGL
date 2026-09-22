function test_handles()
% TEST_HANDLES  Slot table, generations, and the delete hook.

    PsychLVGL('Init', 200, 200);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    parent = PsychLVGL('ObjCreate', scr);
    child = PsychLVGL('ObjCreate', parent);

    plv_assert('parent handle is valid', PsychLVGL('IsValid', parent));
    plv_assert('child handle is valid', PsychLVGL('IsValid', child));
    plv_assert('handles differ', parent ~= child);
    plv_eq('the same object keeps one handle', ...
           PsychLVGL('ObjGetChild', parent, 0), child);

    % deleting the parent must invalidate the child through the delete hook
    PsychLVGL('ObjDelete', parent);
    plv_assert('parent handle is gone', ~PsychLVGL('IsValid', parent));
    plv_assert('child handle is gone too', ~PsychLVGL('IsValid', child));
    plv_throws('stale handle raises InvalidHandle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjGetWidth', child));

    % a reused slot gets a new generation, so the old handle stays invalid
    fresh = PsychLVGL('ObjCreate', scr);
    freedIdx = [mod(parent, 65536), mod(child, 65536)];
    plv_assert('a freed slot is reused', any(mod(fresh, 65536) == freedIdx));
    plv_assert('the reused slot has a new generation', ...
               fresh ~= parent && fresh ~= child);
    plv_assert('the old handle is still invalid', ~PsychLVGL('IsValid', parent));

    plv_throws('handle 0 is not valid', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjGetWidth', 0));
    plv_throws('a handle out of range raises', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjGetWidth', 1e9));
    plv_assert('IsValid does not raise', ~PsychLVGL('IsValid', 1e9));

    % exhausting the table must report, not crash
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 100, 100, struct('MaxObjects', 16));
    scr = PsychLVGL('ScreenActive');
    ok = false;
    try
        for k = 1:64
            PsychLVGL('ObjCreate', scr);
        end
    catch err
        ok = strcmp(err.identifier, 'psychlvgl:Range');
    end
    plv_assert('MaxObjects exhaustion raises Range', ok);

    plv_throws('MaxObjects below the floor is rejected', 'psychlvgl:Range', ...
               @() init_again(struct('MaxObjects', 2)));
    plv_throws('QueueCapacity must be a power of two', 'psychlvgl:Range', ...
               @() init_again(struct('QueueCapacity', 100)));
end

function init_again(opts)
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 100, 100, opts);
end
