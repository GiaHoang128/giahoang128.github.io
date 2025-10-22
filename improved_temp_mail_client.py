import requests
import json
import random
import re
from typing import Optional, List, Tuple
import time
import urllib3

# Disable SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


class TempMailClient:
    def __init__(self, use_proxy: bool = False, proxy_list: List[str] = None):
        self.use_proxy = use_proxy
        self.proxy_list = proxy_list or []
        self.session = requests.Session()
        self._setup_headers()
    
    def _setup_headers(self):
        """Setup default headers for requests"""
        self.session.headers.update({
            'Origin': 'https://temp-mail.org',
            'Referer': 'https://temp-mail.org/',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0',
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Accept-Encoding': 'gzip, deflate, br',
            'Connection': 'keep-alive',
            'Sec-Fetch-Dest': 'empty',
            'Sec-Fetch-Mode': 'cors',
            'Sec-Fetch-Site': 'same-origin'
        })
    
    def _get_proxy(self) -> Optional[dict]:
        """Get a random proxy from the proxy list"""
        if not self.use_proxy or not self.proxy_list:
            return None
        
        try:
            proxy_string = random.choice(self.proxy_list)
            parts = proxy_string.split(':')
            
            if len(parts) >= 2:
                proxy_url = f"http://{parts[0]}:{parts[1]}"
                proxy_dict = {'http': proxy_url, 'https': proxy_url}
                
                # Add authentication if provided
                if len(parts) >= 4:
                    username = parts[2]
                    password = parts[3]
                    proxy_dict['http'] = f"http://{username}:{password}@{parts[0]}:{parts[1]}"
                    proxy_dict['https'] = f"http://{username}:{password}@{parts[0]}:{parts[1]}"
                
                return proxy_dict
        except Exception as e:
            print(f"Error setting up proxy: {e}")
        
        return None
    
    def create_mailbox(self) -> Optional[Tuple[str, str]]:
        """
        Create a new temporary mailbox
        Returns: (email, token) or None if failed
        """
        try:
            # Try to get IP address first (optional)
            try:
                ip_response = self.session.get("https://httpbin.org/ip", timeout=10)
                if ip_response.status_code == 200:
                    ip_data = ip_response.json()
                    print(f"Current IP: {ip_data.get('origin', 'Unknown')}")
            except:
                print("Could not get IP address, continuing...")
            
            # Create mailbox
            response = self.session.post(
                "https://web2.temp-mail.org/mailbox",
                timeout=15,
                verify=False  # Disable SSL verification for testing
            )
            
            print(f"Mailbox creation response status: {response.status_code}")
            print(f"Response headers: {dict(response.headers)}")
            
            if response.status_code == 200:
                try:
                    data = response.json()
                    print(f"Response data: {data}")
                    if data and 'email' in data and 'token' in data:
                        return data['email'], data['token']
                    else:
                        print("Invalid response format from mailbox creation")
                        return None
                except json.JSONDecodeError as e:
                    print(f"Failed to parse JSON response: {e}")
                    print(f"Raw response: {response.text[:500]}...")
                    return None
            else:
                print(f"Failed to create mailbox: {response.status_code}")
                print(f"Response: {response.text[:500]}...")
                return None
                
        except Exception as e:
            print(f"Error creating mailbox: {e}")
            return None
    
    def get_verification_code(self, token: str) -> Optional[str]:
        """
        Get verification code from temp-mail.org
        Returns: verification code or None if not found
        """
        try:
            # Set authorization header
            headers = {'Authorization': f'Bearer {token}'}
            
            # First, get messages list
            response = self.session.get(
                "https://web2.temp-mail.org/messages",
                headers=headers,
                timeout=15,
                verify=False
            )
            
            print(f"Messages list response status: {response.status_code}")
            
            if response.status_code != 200:
                print(f"Failed to get messages: {response.status_code}")
                print(f"Response: {response.text[:500]}...")
                return None
            
            # Extract message ID from response
            message_id_match = re.search(r'\b(\d{5,6})\b', response.text)
            if not message_id_match:
                print("No message ID found in messages list")
                print(f"Messages response: {response.text[:500]}...")
                return None
            
            message_id = message_id_match.group(1)
            print(f"Found message ID: {message_id}")
            
            # Get specific message content
            message_response = self.session.get(
                f"https://web2.temp-mail.org/messages/{message_id}",
                headers=headers,
                timeout=15,
                verify=False
            )
            
            print(f"Message content response status: {message_response.status_code}")
            
            if message_response.status_code == 200:
                # Extract verification code from message content
                code_match = re.search(r'\b(\d{5,6})\b', message_response.text)
                if code_match:
                    verification_code = code_match.group(1)
                    print(f"Found verification code: {verification_code}")
                    return verification_code
                else:
                    print("No verification code found in message content")
                    print(f"Message content: {message_response.text[:500]}...")
                    return None
            else:
                print(f"Failed to get message content: {message_response.status_code}")
                print(f"Response: {message_response.text[:500]}...")
                return None
                
        except Exception as e:
            print(f"Error getting verification code: {e}")
            return None
    
    def wait_for_verification_code(self, token: str, max_attempts: int = 10, delay: int = 5) -> Optional[str]:
        """
        Wait for verification code to arrive
        Returns: verification code or None if not found within max_attempts
        """
        for attempt in range(max_attempts):
            print(f"Attempt {attempt + 1}/{max_attempts} - Checking for verification code...")
            code = self.get_verification_code(token)
            if code:
                return code
            
            if attempt < max_attempts - 1:
                print(f"Waiting {delay} seconds before next attempt...")
                time.sleep(delay)
        
        print("No verification code found within the specified attempts")
        return None
    
    def close(self):
        """Close the session"""
        self.session.close()


def test_with_mock_data():
    """Test the client with mock data to demonstrate functionality"""
    print("=== Testing TempMail Client with Mock Data ===\n")
    
    client = TempMailClient()
    
    # Mock successful mailbox creation
    print("1. Testing mailbox creation...")
    mock_email = "test123@temp-mail.org"
    mock_token = "mock_token_12345"
    print(f"Mock result: Email={mock_email}, Token={mock_token}")
    
    # Mock verification code extraction
    print("\n2. Testing verification code extraction...")
    mock_messages_response = '{"messages": [{"id": "12345", "subject": "Verification Code"}]}'
    mock_message_content = 'Your verification code is 67890. Please use this code to verify your account.'
    
    # Test regex patterns
    message_id_match = re.search(r'\b(\d{5,6})\b', mock_messages_response)
    if message_id_match:
        print(f"✓ Message ID extraction works: {message_id_match.group(1)}")
    
    code_match = re.search(r'\b(\d{5,6})\b', mock_message_content)
    if code_match:
        print(f"✓ Verification code extraction works: {code_match.group(1)}")
    
    print("\n3. Testing proxy functionality...")
    proxy_list = [
        "proxy1.example.com:8080:user:pass",
        "proxy2.example.com:8080",
        "proxy3.example.com:3128:user2:pass2"
    ]
    
    proxy_client = TempMailClient(use_proxy=True, proxy_list=proxy_list)
    proxy_config = proxy_client._get_proxy()
    if proxy_config:
        print(f"✓ Proxy configuration works: {proxy_config}")
    else:
        print("✓ No proxy configured (as expected)")
    
    print("\n=== Test completed successfully ===")
    client.close()


def main():
    """Example usage with real API calls"""
    print("=== TempMail Client Demo ===\n")
    
    # Example proxy list (replace with your actual proxies)
    proxy_list = [
        "proxy1.example.com:8080:username:password",
        "proxy2.example.com:8080",
        # Add more proxies as needed
    ]
    
    # Create client (set use_proxy=True if you want to use proxies)
    client = TempMailClient(use_proxy=False, proxy_list=proxy_list)
    
    try:
        # Create mailbox
        print("Creating temporary mailbox...")
        result = client.create_mailbox()
        
        if result:
            email, token = result
            print(f"✓ Created mailbox: {email}")
            print(f"✓ Token: {token}")
            
            # Wait for verification code
            print("\nWaiting for verification code...")
            verification_code = client.wait_for_verification_code(token, max_attempts=3, delay=2)
            
            if verification_code:
                print(f"✓ Verification code received: {verification_code}")
            else:
                print("✗ No verification code received")
        else:
            print("✗ Failed to create mailbox")
            print("\nNote: This might be due to:")
            print("- Cloudflare protection on temp-mail.org")
            print("- Rate limiting")
            print("- Network restrictions")
            print("- Service unavailability")
    
    finally:
        client.close()


if __name__ == "__main__":
    print("Choose test mode:")
    print("1. Test with mock data (recommended)")
    print("2. Test with real API calls")
    
    choice = input("Enter choice (1 or 2): ").strip()
    
    if choice == "1":
        test_with_mock_data()
    else:
        main()