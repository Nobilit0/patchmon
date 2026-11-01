        1)
            frequency="daily"
            echo
            echo "Daily schedule:"
            echo "  1) Once daily"
            echo "  2) Every 2 hours"
            echo "  3) Every 4 hours"
            echo "  4) Every 6 hours"
            echo "  5) Every 8 hours"
            echo "  6) Every 12 hours"
            while true; do
                prompt daily_choice "Choose 1-6" "1"
                [[ "$daily_choice" =~ ^[1-6]$ ]] && break
                warn "Choose 1, 2, 3, 4, 5, or 6."
            done
            case "$daily_choice" in
                1) interval=24 ;;
                2) interval=2 ;;
                3) interval=4 ;;
                4) interval=6 ;;
                5) interval=8 ;;
                6) interval=12 ;;
            esac
            if (( interval == 24 )); then
                calendar="$(calendar_for_schedule "$start_time" daily "" "" "")"
            else
                start_hour=$((10#${start_time%%:*}))
                start_minute="${start_time##*:}"
                hour_list=""
                # Include all occurrences within 24 hours, including hours
                # before the chosen start time on subsequent days.
                local all_hours=() formatted_hours=() hour
                for ((h=0; h<24; h+=interval)); do
                    hour=$(((start_hour + h) % 24))
                    all_hours+=("$hour")
                done
                # Sort numerically so systemd receives a valid ordered list.
                mapfile -t all_hours < <(printf '%s\n' "${all_hours[@]}" | sort -n)
                for hour in "${all_hours[@]}"; do
                    formatted_hours+=("$(printf '%02d' "$hour")")
                done
                hour_list="$(IFS=,; echo "${formatted_hours[*]}")"
                calendar="*-*-* ${hour_list}:${start_minute}:00"
            fi
            ;;
        2)
            frequency="weekly"
            prompt weekday "Day of week (Mon, Tue, Wed, Thu, Fri, Sat, Sun)" "Sun"
            case "$weekday" in Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;; *) die "Invalid weekday; use Mon, Tue, Wed, Thu, Fri, Sat, or Sun." ;; esac
            ;;
        3)
            frequency="monthly"
            prompt monthday "Day of month (1-28 recommended)" "1"
            [[ "$monthday" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || die "Choose a day from 1 through 28 to ensure it occurs every month."
            ;;
        4)
            frequency="custom"
            prompt custom "Systemd OnCalendar expression (example: Mon..Fri *-*-* 03:00:00)"
            [[ -n "$custom" ]] || die "Custom calendar expression cannot be empty."
            ;;
    esac

    if [[ "$frequency" == "custom" ]]; then
        calendar="$custom"
    elif [[ "$frequency" != "daily" ]]; then
        calendar="$(calendar_for_schedule "$start_time" "$frequency" "$weekday" "$monthday" "")"
    fi

    # Validate the calendar expression with systemd before writing it.
    if ! systemd-analyze calendar "$calendar" >/dev/null 2>&1; then
        die "systemd rejected calendar expression: $calendar"
    fi

    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Scheduled PatchMon automatic patching

[Timer]
OnCalendar=$calendar
Persistent=true
AccuracySec=1min
Unit=patchmon-auto-patch.service

[Install]
WantedBy=timers.target
EOF
    chown root:root "$TIMER_FILE"
    chmod 0644 "$TIMER_FILE"

    systemctl daemon-reload
    systemctl enable --now patchmon-auto-patch.timer
    ok "Timer enabled: $calendar"
    systemctl list-timers patchmon-auto-patch.timer --no-pager || true
}

enable_and_start_service() {
    # The patching service is Type=oneshot. Starting it initiates a real
    # patch cycle immediately; enabling it also starts a cycle at boot.
    info "Enabling patchmon-auto-patch.service at system startup..."
    systemctl daemon-reload
    systemctl enable patchmon-auto-patch.service \
        || die "Failed to enable patchmon-auto-patch.service."

    warn "Starting PatchMon auto-patching now. This may trigger real updates on eligible hosts."
    if ! systemctl start patchmon-auto-patch.service; then
        warn "The service failed. Recent service logs:"
        journalctl -u patchmon-auto-patch.service -n 30 --no-pager >&2 || true
        die "Failed to start patchmon-auto-patch.service."
    fi
    ok "patchmon-auto-patch.service enabled and successfully started."
    info "This is a oneshot service: showing inactive (dead) after completion is normal."
}

main() {
    require_root
    echo
    printf '%sPatchMon Auto-Patch Installer%s\n' "$GREEN" "$NC"
    echo "This installs the automation package and optionally configures a systemd timer."
    echo
    install_dependencies
    download_and_extract
    setup_venv
    configure_environment

    local dry_status=0
    run_dry_run || dry_status=$?

    if [[ "$dry_status" -eq 1 ]]; then
        if ! confirm "Dry-run failed. Continue to timer setup anyway?"; then
            warn "Installation completed, but timer was not enabled."
            exit 0
        fi
    elif [[ "$dry_status" -eq 2 ]]; then
        if ! confirm "You skipped dry-run. Continue to timer setup anyway?"; then
            warn "Installation completed, but timer was not enabled."
            exit 0
        fi
    fi

    configure_timer
    enable_and_start_service
    echo
    ok "Installation workflow finished."
    echo "Environment: $ENV_FILE (root:root, 0600)"
    echo "Program:     $INSTALL_DIR/patchmon_auto_patch.py"
    echo "Logs:        $LOG_DIR/patchmon-auto-patch.log"
    echo "Timer:       systemctl status patchmon-auto-patch.timer"
    echo "Service:     systemctl status patchmon-auto-patch.service"
    echo "Enablement:  systemctl is-enabled patchmon-auto-patch.service"
    echo "Logs:        journalctl -u patchmon-auto-patch.service -n 100 --no-pager"
}
main "$@"
