#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdarg.h>
#include <netdb.h>
#include <errno.h>
#include "socket.h"

//---------------------------------- On met en place la connexion avec la socket --------------------------------

int connexion(int s, char *serveur, char *port){
	// structure pour faire la demande
	struct addrinfo hints;
	// structure pour stocker et lire les rÃÂ©sultats
	struct addrinfo *result, *rp;
	result = NULL;
	rp=NULL;
	// variables pour tester si les fonctions donnent un rÃÂ©sultats ou une erreur
	int res=0;
	int bon=0;
	// Des variable pour contenir de adresse de machine et des numero de port afin de les afficher
	char hname[NI_MAXHOST], sname[NI_MAXSERV];

	//On rempli la structure hints de demande d'adresse
	memset(&hints, 0, sizeof(struct addrinfo));
	hints.ai_family = AF_UNSPEC;    // IPv4 ou IPv6
	hints.ai_socktype = SOCK_STREAM; // socket flux connectÃÂ©e
	hints.ai_flags = 0;  
	hints.ai_protocol = 0;          //Any protocol 
	hints.ai_addrlen = 0; 
	hints.ai_addr = NULL;           
	hints.ai_canonname = NULL;
	hints.ai_next = NULL;
 
	//On essaye la connexion avec les parametres recuperes (serveur, port)
	res = getaddrinfo(serveur, port, &hints, &result);
	if (res != 0) { // c'est une erreur
		fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(res));
		exit(1);
	}
 
	//On teste jusqu'a pouvoir nous connecter
	rp = result;
	bon = 0;
	while (rp != NULL) {
	// on parcourt la liste pour en trouver une qui convienne

		// on rÃÂ©cupÃÂ¨re des informations affichables
		res = getnameinfo(rp->ai_addr, rp->ai_addrlen,hname, NI_MAXHOST,sname, NI_MAXSERV,NI_NUMERICSERV|NI_NUMERICHOST);
		if (res != 0) {
			fprintf(stderr, "getnameinfo: %s\n", gai_strerror(res));
			exit (1);
		}
    
		// on essaye
		s = socket(rp->ai_family, rp->ai_socktype,rp->ai_protocol);
		// si le rÃÂ©sultat est -1 cela n'a pas fonctionnÃÂ© on recommence avec la prochaine
		if (s == -1) {
			perror("Creation de la socket");
			rp = rp->ai_next;
			continue;
		}
   
		// si la socket a ÃÂ©tÃÂ© obtenue, on essaye de se connecter
		res = connect(s, rp->ai_addr, rp->ai_addrlen);
		if (res == 0 ) {// cela a fonctionnÃÂ© on est connectÃÂ©
			bon = 1;
			freeaddrinfo(result);
			return s;
		} else  { // sinon le bind a ÃÂ©tÃÂ© impossible, il faut fermer la socket
			perror("ERR: Imposible de se connecter");
			close (s);
			return -1;
		}
	rp = rp->ai_next;
	}

	if (bon == 0) { // Cela n'a jamais fonctionnÃÂ©
		fprintf(stderr, "Aucune connexion possible\n");
		return -1;
	}
	freeaddrinfo(result);
	return -1;
}
