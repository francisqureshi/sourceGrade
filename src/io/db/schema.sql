-- Projects (top-level container)
CREATE TABLE projects (
	id SERIAL PRIMARY KEY,
	name TEXT NOT NULL,
	created_at TIMESTAMPTZ DEFAULT NOW(),
	modified_at TIMESTAMPTZ DEFAULT NOW(),
	default_frame_rate NUMERIC(10,2),
	default_resolution_width INT,
	default_resolution_height INT,
	working_color_space TEXT DEFAULT 'rec709'
);
-- Source media (actual files on disk)
CREATE TABLE sources (
    id SERIAL PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    codec TEXT,                    -- 'prores_4444', 'h264', etc.
    duration_frames INT,
    frame_rate NUMERIC(10,2),
    width INT,
    height INT,
    color_space TEXT,              -- 'rec709', 'rec2020', etc.
    timecode_start TEXT,           -- SMPTE timecode
    created_at TIMESTAMPTZ DEFAULT NOW(),
    file_modified_at TIMESTAMPTZ,
    file_size_bytes BIGINT
);


-- Timelines (one project can have multiple sequences/timelines)
CREATE TABLE timelines (
    id SERIAL PRIMARY KEY,
    project_id INT REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    frame_rate NUMERIC(10,2),
    duration_frames INT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    modified_at TIMESTAMPTZ DEFAULT NOW()
);

-- Timeline clips (instances of sources placed on timeline)
CREATE TABLE timeline_clips (
    id SERIAL PRIMARY KEY,
    timeline_id INT REFERENCES timelines(id) ON DELETE CASCADE,
    source_id INT REFERENCES sources(id) ON DELETE RESTRICT,
    
    -- Source media range (what part of the source to use)
    source_in_frame INT NOT NULL,
    source_out_frame INT NOT NULL,
    
    -- Timeline placement (where it sits on timeline)
    timeline_in_frame INT NOT NULL,
    timeline_out_frame INT NOT NULL,
    
    -- Track/layer
    track_index INT DEFAULT 0,
    
    -- Speed/retime
    speed_multiplier NUMERIC(10,4) DEFAULT 1.0,
    
    -- Metadata
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    modified_at TIMESTAMPTZ DEFAULT NOW()
);

-- Grade nodes (color correction stack for each timeline clip)
CREATE TABLE grade_nodes (
    id SERIAL PRIMARY KEY,
    timeline_clip_id INT REFERENCES timeline_clips(id) ON DELETE CASCADE,
    
    node_type TEXT NOT NULL,       -- 'primary', 'curves', 'lut', 'hsl', 'blur'
    node_label TEXT,               -- user-defined name
    parameters JSONB NOT NULL,     -- all node params as JSON
    
    -- Node graph structure
    position INT NOT NULL,         -- order in serial node graph
    enabled BOOLEAN DEFAULT true,
    
    -- Future: node graph connections for parallel/layer nodes
    -- input_node_id INT REFERENCES grade_nodes(id),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    modified_at TIMESTAMPTZ DEFAULT NOW()
);

-- Versions/snapshots (track project state over time)
CREATE TABLE versions (
    id SERIAL PRIMARY KEY,
    project_id INT REFERENCES projects(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    description TEXT,
    created_by TEXT,               -- user name
    snapshot_data JSONB            -- could store full project state
);

-- Indexes for performance
CREATE INDEX idx_timeline_clips_timeline ON timeline_clips(timeline_id);
CREATE INDEX idx_timeline_clips_source ON timeline_clips(source_id);
CREATE INDEX idx_grade_nodes_clip ON grade_nodes(timeline_clip_id);
CREATE INDEX idx_sources_path ON sources(path);

-- Trigger to update modified_at timestamps
CREATE OR REPLACE FUNCTION update_modified_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.modified_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_projects_modified_at
    BEFORE UPDATE ON projects
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at();

CREATE TRIGGER update_timelines_modified_at
    BEFORE UPDATE ON timelines
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at();

CREATE TRIGGER update_timeline_clips_modified_at
    BEFORE UPDATE ON timeline_clips
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at();
