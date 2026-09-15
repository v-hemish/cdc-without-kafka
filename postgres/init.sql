CREATE TABLE customers (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    plan TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE customers REPLICA IDENTITY FULL;

INSERT INTO customers (name, plan) VALUES
    ('Alice', 'free'),
    ('Bob', 'pro'),
    ('Charlie', 'free');

CREATE PUBLICATION cdc_publication
FOR TABLE customers;
