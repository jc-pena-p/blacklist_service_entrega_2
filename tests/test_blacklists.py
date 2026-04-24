import uuid


def test_health_endpoint(client):
    response = client.get('/health')
    assert response.status_code == 200
    assert response.get_json()['status'] == 'ok'


def test_create_blacklist_entry(client, auth_headers):
    payload = {
        'email': 'persona@example.com',
        'app_uuid': str(uuid.uuid4()),
        'blocked_reason': 'fraude',
    }

    response = client.post('/blacklists', json=payload, headers=auth_headers)

    assert response.status_code == 201
    body = response.get_json()
    assert body['message'] == 'Email added to blacklist'
    assert body['data']['email'] == 'persona@example.com'
    assert body['data']['blocked_reason'] == 'fraude'


def test_create_duplicate_blacklist_entry_returns_409(client, auth_headers):
    payload = {
        'email': 'repetido@example.com',
        'app_uuid': str(uuid.uuid4()),
        'blocked_reason': 'spam',
    }

    first_response = client.post('/blacklists', json=payload, headers=auth_headers)
    second_response = client.post('/blacklists', json=payload, headers=auth_headers)

    assert first_response.status_code == 201
    assert second_response.status_code == 409


def test_lookup_blacklisted_email(client, auth_headers):
    payload = {
        'email': 'exists@example.com',
        'app_uuid': str(uuid.uuid4()),
        'blocked_reason': 'spam',
    }
    client.post('/blacklists', json=payload, headers=auth_headers)

    response = client.get('/blacklists/exists@example.com', headers=auth_headers)

    assert response.status_code == 200
    body = response.get_json()
    assert body['is_blacklisted'] is True
    assert body['blocked_reason'] == 'spam'


def test_lookup_non_blacklisted_email(client, auth_headers):
    response = client.get('/blacklists/no-registrado@example.com', headers=auth_headers)

    assert response.status_code == 200
    body = response.get_json()
    assert body['is_blacklisted'] is False
    assert body['blocked_reason'] is None


def test_requires_bearer_token(client):
    response = client.get('/blacklists/no-registrado@example.com')
    assert response.status_code == 401


def test_validates_payload(client, auth_headers):
    payload = {
        'email': 'correo-invalido',
        'app_uuid': 'not-a-uuid',
        'blocked_reason': 'x' * 256,
    }

    response = client.post('/blacklists', json=payload, headers=auth_headers)

    assert response.status_code == 400
    body = response.get_json()
    assert body['message'] == 'Validation error'
    assert 'email' in body['errors']
    assert 'app_uuid' in body['errors']
    assert 'blocked_reason' in body['errors']
