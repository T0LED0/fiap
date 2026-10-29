CREATE TABLE IF NOT EXISTS api_keys (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    
    -- key_hash armazena o hash SHA-256 da chave, que tem 64 caracteres hexadecimais
    key_hash VARCHAR(64) NOT NULL UNIQUE, 
    
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Seed do hash SHA-256 da chave interna de serviço para comunicação inter-serviços
INSERT INTO api_keys (name, key_hash, is_active)
VALUES ('evaluation-service-internal', '8a20f54156f1cceefbc17f98da80a7f6b0ccddffe465e20a758174bdd63520d6', true)
ON CONFLICT (key_hash) DO NOTHING;