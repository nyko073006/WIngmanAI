-- DEV: reset today's AI usage counters so the new 999-limit takes effect immediately
DELETE FROM usage_counters WHERE date = current_date;
