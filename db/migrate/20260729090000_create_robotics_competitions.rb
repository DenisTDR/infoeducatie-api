class CreateRoboticsCompetitions < ActiveRecord::Migration[8.1]
  LIVE_TURN_STATES = %w[offered active turnover].freeze

  def change
    create_table :robotics_competitions do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.datetime :starts_at, null: false
      t.integer :duration_seconds, null: false, default: 20.hours.to_i
      t.integer :team_allocation_seconds, null: false, default: 3.hours.to_i
      t.integer :turn_duration_seconds, null: false, default: 10.minutes.to_i
      t.integer :claim_window_seconds, null: false, default: 60
      t.integer :turnover_seconds, null: false, default: 60
      t.bigint :queue_sequence, null: false, default: 0
      t.bigint :turn_sequence, null: false, default: 0

      t.timestamps
    end

    add_index :robotics_competitions, :slug, unique: true
    add_check_constraint :robotics_competitions,
      "duration_seconds > 0",
      name: "robotics_competitions_duration_positive"
    add_check_constraint :robotics_competitions,
      "team_allocation_seconds > 0",
      name: "robotics_competitions_allocation_positive"
    add_check_constraint :robotics_competitions,
      "turn_duration_seconds > 0 AND turn_duration_seconds <= duration_seconds",
      name: "robotics_competitions_turn_duration_valid"
    add_check_constraint :robotics_competitions,
      "claim_window_seconds > 0",
      name: "robotics_competitions_claim_window_positive"
    add_check_constraint :robotics_competitions,
      "turnover_seconds >= 0",
      name: "robotics_competitions_turnover_nonnegative"

    create_table :robotics_teams do |t|
      t.references :robotics_competition,
        null: false,
        foreign_key: {on_delete: :cascade}
      t.string :name, null: false
      t.integer :position, null: false
      t.string :pin_digest, null: false
      t.string :pin_fingerprint, null: false
      t.integer :authentication_version, null: false, default: 0
      t.boolean :enabled, null: false, default: true
      t.boolean :ready, null: false, default: false
      t.datetime :cooldown_until

      t.timestamps
    end

    add_index :robotics_teams,
      [:robotics_competition_id, :name],
      unique: true
    add_index :robotics_teams,
      [:robotics_competition_id, :position],
      unique: true
    add_index :robotics_teams,
      [:robotics_competition_id, :pin_fingerprint],
      unique: true,
      name: "index_robotics_teams_on_competition_and_pin"
    add_check_constraint :robotics_teams,
      "position > 0",
      name: "robotics_teams_position_positive"

    create_table :robotics_queue_entries do |t|
      t.references :robotics_competition,
        null: false,
        foreign_key: {on_delete: :cascade}
      t.references :robotics_team,
        null: false,
        index: false,
        foreign_key: {on_delete: :cascade}
      t.bigint :sequence_number, null: false
      t.datetime :requested_at, null: false

      t.timestamps
    end

    add_index :robotics_queue_entries, :robotics_team_id, unique: true
    add_index :robotics_queue_entries,
      [:robotics_competition_id, :sequence_number],
      unique: true,
      name: "index_robotics_queue_on_competition_and_sequence"

    create_table :robotics_turns do |t|
      t.references :robotics_competition,
        null: false,
        foreign_key: {on_delete: :cascade}
      t.references :robotics_team,
        null: false,
        foreign_key: {on_delete: :restrict}
      t.bigint :sequence_number, null: false
      t.string :state, null: false
      t.datetime :offered_at, null: false
      t.datetime :offer_expires_at, null: false
      t.datetime :started_at
      t.datetime :session_ends_at
      t.datetime :ended_at
      t.datetime :turnover_ends_at
      t.integer :reserved_seconds
      t.integer :charged_seconds
      t.string :stop_reason
      t.references :stopped_by,
        type: :integer,
        foreign_key: {to_table: :users, on_delete: :nullify}

      t.timestamps
    end

    add_index :robotics_turns,
      [:robotics_competition_id, :sequence_number],
      unique: true,
      name: "index_robotics_turns_on_competition_and_sequence"
    add_index :robotics_turns,
      :robotics_competition_id,
      unique: true,
      where: "state IN ('#{LIVE_TURN_STATES.join("','")}')",
      name: "index_robotics_turns_one_live_lease"
    add_check_constraint :robotics_turns,
      "state IN ('offered', 'active', 'turnover', 'completed', " \
        "'passed', 'expired', 'withdrawn')",
      name: "robotics_turns_state_valid"
    add_check_constraint :robotics_turns,
      "offer_expires_at >= offered_at",
      name: "robotics_turns_offer_window_valid"
    add_check_constraint :robotics_turns,
      "reserved_seconds IS NULL OR reserved_seconds > 0",
      name: "robotics_turns_reserved_positive"
    add_check_constraint :robotics_turns,
      "charged_seconds IS NULL OR charged_seconds >= 0",
      name: "robotics_turns_charged_nonnegative"

    create_table :robotics_time_entries do |t|
      t.references :robotics_competition,
        null: false,
        foreign_key: {on_delete: :cascade}
      t.references :robotics_team,
        null: false,
        foreign_key: {on_delete: :restrict}
      t.references :robotics_turn,
        index: false,
        foreign_key: {on_delete: :restrict}
      t.string :kind, null: false
      t.integer :amount_seconds, null: false
      t.text :reason, null: false
      t.references :actor,
        type: :integer,
        foreign_key: {to_table: :users, on_delete: :nullify}

      t.timestamps
    end

    add_index :robotics_time_entries,
      :robotics_turn_id,
      unique: true,
      where: "robotics_turn_id IS NOT NULL"
    add_index :robotics_time_entries,
      :robotics_team_id,
      unique: true,
      where: "kind = 'initial_grant'",
      name: "index_robotics_time_entries_one_initial_grant"
    add_index :robotics_time_entries,
      [:robotics_team_id, :created_at]
    add_check_constraint :robotics_time_entries,
      "kind IN ('initial_grant', 'session_usage', 'admin_adjustment')",
      name: "robotics_time_entries_kind_valid"
    add_check_constraint :robotics_time_entries,
      "amount_seconds <> 0",
      name: "robotics_time_entries_amount_nonzero"
  end
end
