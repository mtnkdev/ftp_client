#ifndef __SOCKET_H
#define __SOCKET_H

/**
 * Met en place la socket avec le serveur et le port correspondant
 * @param s : la socket
 * @param serveur : la chaine de caracteres indiquant le serveur
 * @param port : la chaine de caracteres indiquant le port
 * @return la socket connectee
 */
int connexion(int s, char *serveur, char *port);

#endif
