import requests
import json
import random
import re
from typing import Optional, List, Tuple
import time


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
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0'
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
            # First, get IP address (as in original code)
            ip_response = self.session.get("https://ifconfig.co/ip", timeout=10)
            print(f"Current IP: {ip_response.text.strip()}")
            
            # Create mailbox
            response = self.session.post(
                "https://web2.temp-mail.org/mailbox",
                timeout=10
            )
            
            if response.status_code == 200:
                data = response.json()
                if data and 'email' in data and 'token' in data:
                    return data['email'], data['token']
                else:
                    print("Invalid response format from mailbox creation")
                    return None
            else:
                print(f"Failed to create mailbox: {response.status_code}")
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
                timeout=10
            )
            
            if response.status_code != 200:
                print(f"Failed to get messages: {response.status_code}")
                return None
            
            # Extract message ID from response
            message_id_match = re.search(r'\b(\d{5,6})\b', response.text)
            if not message_id_match:
                print("No message ID found in messages list")
                return None
            
            message_id = message_id_match.group(1)
            print(f"Found message ID: {message_id}")
            
            # Get specific message content
            message_response = self.session.get(
                f"https://web2.temp-mail.org/messages/{message_id}",
                headers=headers,
                timeout=10
            )
            
            if message_response.status_code == 200:
                # Extract verification code from message content
                code_match = re.search(r'\b(\d{5,6})\b', message_response.text)
                if code_match:
                    verification_code = code_match.group(1)
                    print(f"Found verification code: {verification_code}")
                    return verification_code
                else:
                    print("No verification code found in message content")
                    return None
            else:
                print(f"Failed to get message content: {message_response.status_code}")
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


def main():
    """Example usage"""
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
            print(f"Created mailbox: {email}")
            print(f"Token: {token}")
            
            # Wait for verification code
            print("\nWaiting for verification code...")
            verification_code = client.wait_for_verification_code(token)
            
            if verification_code:
                print(f"Verification code received: {verification_code}")
            else:
                print("No verification code received")
        else:
            print("Failed to create mailbox")
    
    finally:
        client.close()


if __name__ == "__main__":
    main()