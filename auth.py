import httpx
import logging
import datetime

# Standard-Logging anstelle von structlog
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class AuthenticationError(Exception):
    """Wird geworfen, wenn die Authentifizierung fehlschlägt."""
    pass

class Token:
    def __init__(self, access_token, expires_in, refresh_token=None, refresh_expires_in=None):
        now = datetime.datetime.now()
        self._expires_at = now + datetime.timedelta(seconds=expires_in)
        self._refresh_expires_at = now + datetime.timedelta(
            seconds=refresh_expires_in) if refresh_token and refresh_expires_in else None
        self.access_token = access_token
        self.refresh_token = refresh_token

    @property
    def expires_in(self):
        return max(0, (self._expires_at - datetime.datetime.now()).total_seconds())

    @property
    def is_expired(self):
        # Puffer von 5 Sekunden, um Zeitüberschneidungen zu vermeiden
        return self.expires_in <= 5

    @classmethod
    def from_json(cls, data):
        try:
            return cls(
                access_token=data['access_token'],
                expires_in=data['expires_in'],
                refresh_token=data.get('refresh_token'),
                refresh_expires_in=data.get('refresh_expires_in')
            )
        except KeyError as e:
            raise AuthenticationError(f"Ungültiges Token-Format vom Server: Fehlendes Feld {e}")

class KeycloakAuth(httpx.Auth):
    """
    Synchroner HTTPX-Auth-Handler für Keycloak via OpenID Connect.
    """
    def __init__(self, client: httpx.Client, client_id: str, client_secret: str, realm: str = "master"):
        self.client = client
        self.client_id = client_id
        self.client_secret = client_secret
        self.realm = realm
        self.endpoints = None
        self.token = None

    def _load_endpoints(self):
        """Lädt die OIDC-Konfiguration vom Well-Known Pfad."""
        discovery_url = f"/realms/{self.realm}/.well-known/openid-configuration"
        logger.info(f"Lade OIDC-Konfiguration von {discovery_url}")
        
        # Hinweis: Da dies innerhalb von auth_flow aufgerufen wird, 
        # nutzen wir yield, um den Request über den Client abzusetzen.
        request = self.client.build_request("GET", discovery_url)
        response = yield request
        response.read()

        if response.status_code != 200:
            raise AuthenticationError(
                f"OIDC-Konfiguration konnte nicht geladen werden ({response.status_code}): {response.text}"
            )
        
        self.endpoints = response.json()

    def auth_flow(self, request):
        # 1. Endpunkte (Discovery) abrufen
        if self.endpoints is None:
            yield from self._load_endpoints()

        # 2. Token abrufen oder erneuern
        if self.token is None or self.token.is_expired:
            logger.info("Fordere neues Access Token an (Client Credentials Flow)")
            
            token_request = self.client.build_request(
                "POST",
                self.endpoints['token_endpoint'],
                data={
                    'grant_type': 'client_credentials',
                    'client_id': self.client_id,
                    'client_secret': self.client_secret
                }
            )
            response = yield token_request
            response.read()

            if response.status_code != 200:
                raise AuthenticationError(
                    f"Token-Abruf fehlgeschlagen ({response.status_code}): {response.text}"
                )

            self.token = Token.from_json(response.json())

        # 3. Den eigentlichen Request mit dem Token versehen
        request.headers['Authorization'] = f"Bearer {self.token.access_token}"
        response = yield request

        # Optional: Automatisches Handling von 401 Unauthorized
        if response.status_code == 401:
            logger.warning("Request wurde mit 401 abgelehnt. Das Token ist möglicherweise ungültig.")
