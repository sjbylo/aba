#!/bin/bash 

echo ssh core@$(cat iso-agent-based/rendezvousIP)
ssh core@$(cat iso-agent-based/rendezvousIP)

